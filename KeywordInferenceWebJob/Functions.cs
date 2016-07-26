using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Azure.WebJobs;
using Microsoft.WindowsAzure.Storage;
using Newtonsoft.Json.Linq;
using Microsoft.WindowsAzure.Storage.Table;
using Microsoft.ServiceBus.Messaging;
using System.Net;
using Newtonsoft.Json;
using System.Diagnostics;
using Microsoft.WindowsAzure.Storage.Queue;
using GeoJSON.Net;
using GeoJSON.Net.Geometry;

namespace KeywordInferenceWebJob
{
    public class Functions
    {
       
        public static void ProcessQueueMessage([QueueTrigger("%KEYWORD_INFERENCE_INPUT_QUEUE_NAME%")] CloudQueueMessage retrievedMessage,
            CloudStorageAccount storageAccount,
            TextWriter log)
        {
            ReferenceData.LoadReferenceData(storageAccount);

            if (retrievedMessage != null)
            {
                try
                {
                    var text = Encoding.UTF8.GetString(retrievedMessage.AsBytes);
                    string prunedMsg = text?.Replace(@"\n", "")?.Replace(@"\r", "");

                    Newtonsoft.Json.Linq.JObject payload = Newtonsoft.Json.Linq.JObject.Parse(prunedMsg);

                    var messages = CreateIngestObjects(payload);
                    foreach (var ingestObj in messages.Item1)
                    {
                        IngestKeyword(ingestObj);
                    }
                    if (messages.Item2 != null)
                    {
                        if (messages.Item2.Groups?.Count > 0)
                        {
                            IngestSentence(messages.Item2);
                        }
                    }

                }
                catch (Exception ex)
                {
                    log.WriteLine(ex.Message);
                    throw (ex);
                }
               
            }
        }
       
        private static Tuple<List<KeywordMessage>, SentenceMessage> CreateIngestObjects(JObject payload)
        {
            var keywordMessages = new List<KeywordMessage>();

            var textSource = payload.SelectToken("message.source")?.ToString();

            string sentence;
            string language;
            string messageId;
            DateTime created;

            // check if we get the message from NLP service - in this case the source is set Twitter, Facebook, ...
            if (!textSource.Contains("http"))
            {
                textSource = payload.SelectToken("message.source")?.ToString();
                sentence = payload.SelectToken("message.sentence")?.ToString();
                language = payload.SelectToken("message.lang")?.ToString();
                messageId = payload.SelectToken("message.id")?.ToString();
                created = DateTime.Parse(payload.SelectToken("message.created_at")?.ToString());
            }
            else
            {
                // in this case we only process Twitter data
                textSource = "twitter";
                sentence = payload.SelectToken("message.text")?.ToString();
                language = payload.SelectToken("message.lang")?.ToString();
                // Twitter tags Indonesian as in (correct is id)
                if (language == "in")
                {
                    language = "id";
                }
                messageId = payload.SelectToken("message.id")?.ToString();
                created = DateTime.Parse(payload.SelectToken("message.created_at")?.ToString());
            }

            List<ReferencedLocation> locations = null;
            var words = TokenizeAndNormalize(payload, language);

            locations = ReferenceData.GetGeoLocations(
                payload.SelectToken("message.geo").ToString(), 
                (textSource == ReferenceData.TWITTER_ID_STR), 
                words, 
                language
            );
            if (textSource == ReferenceData.TWITTER_ID_STR)
            {
                var userId = payload.SelectToken("message.user_id")?.ToString();
                if (userId != null)
                {
                    var loc = InfereLocationFromTwitterUserHandle(userId);
                    if (loc != null)
                    {
                        locations.Add(loc);
                    }
                }
            }
            var keywords = InferKeywords(language, words);
            // create a message for each keyword
            foreach (string keyword in keywords) 
            {
                KeywordMessage keywordMessage = new KeywordMessage();
                keywordMessages.Add(keywordMessage);
                keywordMessage.Language = language;
                keywordMessage.Keyword = keyword;
                keywordMessage.Sentence = sentence;
                keywordMessage.Source = textSource;
                keywordMessage.Created = created;
                keywordMessage.Locations = locations;
            }

            var sentenceMessage = new SentenceMessage()
            {
                MessageId = messageId,
                Language = language,
                Keywords = keywords.ToList(),
                Sentence = sentence,
                Source = textSource,
                Created = created,
                Locations = locations,
                Sectors = InferSectors(language, words).ToList(),
                Groups = InferGroups(language, words).ToList(),
                Statuses = InferStatuses(language, words).ToList()
            };

            if (!(sentenceMessage.Keywords.Any() || sentenceMessage.Groups.Any() || sentenceMessage.Sectors.Any() || sentenceMessage.Statuses.Any()))
            {
                Trace.TraceInformation("No redeeming qualities to '{0}', dropping.", sentence);
                // sentenceMessage = null;
            }
            // returns an anonymous which serializes according to the scoring service contract
            return Tuple.Create(keywordMessages, sentenceMessage);
        }

        private static IEnumerable<string> TokenizeAndNormalize(JObject payload, string language)
        {
            string tokenSelector = null;

            switch (language)
            {
                case "en":
                    tokenSelector = "nlp.words";
                    break;

                default:
                    tokenSelector = "nlp.tokens";
                    break;
            }

            var words = payload.SelectToken(tokenSelector);
            // in the case we didn't run nlp, we tokenize the sentences using a simple approach
            if (words == null)
            {
                var text = payload.SelectToken("message.text").ToString();
                return text.Split(' ', ',', '.').Select(x => x.ToLower()).Distinct().Where(x => x != null);
            }
            else
            {
                return words.Select(x => x.ToString().ToLower()).Distinct();
            }
        }

        private static IEnumerable<string> InferKeywords(string language, IEnumerable<string> words)
        {
            return ReferenceData.GetKeywordsForWords(language, words);
        }

        private static IEnumerable<string> InferSectors(string language, IEnumerable<string> words)
        {
            return new string[0];
            // return ReferenceData.GetSectorsForWords(language, words);
        }

        private static IEnumerable<string> InferGroups(string language, IEnumerable<string> words)
        {
            return ReferenceData.GetGroupsForWords(language, words);
        }

        private static IEnumerable<string> InferStatuses(string language, IEnumerable<string> words)
        {
            return new string[0];
            //return ReferenceData.GetStatusesForWords(language, words);
        }

        private static void IngestKeyword(KeywordMessage message)
        {
            string json = JsonConvert.SerializeObject(message);
            SendMessage(message.Source, json, ReferenceData.GetEventHubClient());
        }
        private static void IngestSentence(SentenceMessage message)
        { 
             string json = JsonConvert.SerializeObject(message); 
             SendMessage(message.Source, json, ReferenceData.GetSentenceEventHubClient()); 
        }

    private static void SendMessage(string messagePK, string json, EventHubClient queue)
        {
            Trace.TraceInformation("Sending {0} PK{1}: {2}", queue.Path, messagePK, json);
            // set the partitionkey to the text source (e.g. twitter)
            EventData data = new EventData(Encoding.UTF8.GetBytes(json)) { PartitionKey = messagePK };

            try
            {
                // if (message.HasLocations())
                {
                    queue.Send(data);
                }
            }
            catch (Exception ex)
            {
                // error code 5002 means we're trotteled - this requires the increase of the service bus TU
                // Trace.TraceError(ex.Message);
                throw (ex);
            }
        }

        private class UserEntity : TableEntity
        {
            public string location { get; set; }
        }

        private class Location
        {
            public double lat { get; set; }
            public double lon { get; set; }
            public float confidence { get; set; }
        }
        private static ReferencedLocation InfereLocationFromTwitterUserHandle(string userId)
        {
            ReferencedLocation userLocObj = null;
            string partitionFilter = TableQuery.GenerateFilterCondition("PartitionKey", QueryComparisons.Equal, userId.Substring(0, 2));
            string rowFilter = TableQuery.GenerateFilterCondition("RowKey", QueryComparisons.Equal, userId);
            string finalFilter = TableQuery.CombineFilters(partitionFilter, TableOperators.And, rowFilter);
            TableQuery<UserEntity> query =  new TableQuery<UserEntity>().Where(finalFilter);

            try
            {
                var response = ReferenceData.GetUsersTable().ExecuteQuery(query).Select(x => x.location);
                if (response.Count() > 0)
                {
                    var loc = response.First();
                    if (loc != null)
                    {
                        var locObj = JsonConvert.DeserializeObject<Location>(loc);
                        userLocObj = new ReferencedLocation()
                        {
                            Location = new Point(new GeographicPosition(locObj.lat, locObj.lon)),
                            Probability = locObj.confidence,
                            InferenceType = "TwitterUserHandle"
                        };
                    }
                }
            }
            catch (Microsoft.WindowsAzure.Storage.StorageException) { } // user table might not exist yet 
            return userLocObj;
        }

    }
}
