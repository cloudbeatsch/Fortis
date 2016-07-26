using FuzzyString;
using GeoJSON.Net;
using GeoJSON.Net.Geometry;
using Microsoft.Azure;
using Microsoft.ServiceBus.Messaging;
using Microsoft.WindowsAzure;
using Microsoft.WindowsAzure.Storage;
using Microsoft.WindowsAzure.Storage.Blob;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace KeywordInferenceWebJob
{
    using Microsoft.WindowsAzure.Storage.Table;
    using CategoryMap = Dictionary<string, Dictionary<string, Tuple<List<string>, string>>>;

    public class ReferenceData
    {
        private static System.Object referenceData = new System.Object();

        // The table for the tweet user location inference
        private static CloudTable usersTable;

        // The event hubs from which we're going to be reading
        private static EventHubClient eventHubClient, eventHubSentenceClient;

        // Dict of string to likely inferred location e.g. London->51.5074° N, 0.1278° W
        private static Dictionary<string, Dictionary<string, Geo>> locationInferenceDictionary;

        // { language_code : (keywords,..) }
        private static Dictionary<string, HashSet<string>> keywordLists;

        // Translations to the canonical language (default=en)
        private static Dictionary<string, Dictionary<string, string>> translations;

        // { lang : { keyword, ([keywords,...], sector]) } }
        private static CategoryMap sectorsByKeyword;

        // { lang : { keyword, ([keywords,...], group]) } }
        private static CategoryMap groupsByKeyword;

        // { lang : { keyword, ([keywords,...], status]) } }
        private static CategoryMap statusesByKeyword;

        // Ensure we only load reference data once
        private static bool loaded = false;

        public const string RSS_ID_STR = "rss";
        public const string TWITTER_ID_STR = "twitter";
        public const string FB_MSG_ID_STR = "facebook-messages";
        public const string FB_CMT_ID_STR = "facebook-comments";
        
        private enum Sources { 
            RSS = 0, TWITTER = 1, 
            FB_MESSAGES = 2, 
            FB_COMMENTS = 3, 
            NR_OF_SOURCES = 4 
        };

        public static void LoadReferenceData(CloudStorageAccount storageAccount)
        {
            lock (referenceData)
            {
                if (loaded == false)
                {
                    eventHubClient = EventHubClient.CreateFromConnectionString(
                        CloudConfigurationManager.GetSetting("KEYWORD_EVENTHUB_CONNECTION_STRING"),
                        CloudConfigurationManager.GetSetting("KEYWORD_EVENTHUB_NAME"));

                    eventHubSentenceClient = EventHubClient.CreateFromConnectionString(
                        CloudConfigurationManager.GetSetting("SENTENCE_EVENTHUB_CONNECTION_STRING"),
                        CloudConfigurationManager.GetSetting("SENTENCE_EVENTHUB_NAME"));

                    var container = storageAccount.CreateCloudBlobClient().GetContainerReference(
                        CloudConfigurationManager.GetSetting("REFERENCE_DATA_BLOB_CONTAINER")
                    );
                    
                    locationInferenceDictionary = LoadLocationInferenceDictionary(
                        container.GetDirectoryReference("locations")
                    );

                    var pctGeoStorageAccount = CloudStorageAccount.Parse(
                            CloudConfigurationManager.GetSetting("PCT_GEO_TWIT_CONNECTION_STR"));
                    usersTable = pctGeoStorageAccount.CreateCloudTableClient().GetTableReference(
                            CloudConfigurationManager.GetSetting("USER_TABLE"));

                    keywordLists = LoadKeywords(container.GetDirectoryReference("keywords"));

                    groupsByKeyword = LoadKeyphraseLists(container.GetDirectoryReference("groups"));
                    sectorsByKeyword = LoadKeyphraseLists(container.GetDirectoryReference("sectors"));
                    statusesByKeyword = LoadKeyphraseLists(container.GetDirectoryReference("statuses"));

                    loaded = true;
                }
            }
        }

        public static EventHubClient GetEventHubClient()
        {
            return eventHubClient;
        }

        public static EventHubClient GetSentenceEventHubClient()
        { 
            return eventHubSentenceClient; 
        }

    private static void TraverseReferenceData(CloudBlobDirectory root, Action<CloudBlob, string> onFile)
        {
            // Iterate through the immediate subdirs of root (which represent a supported language)
            // and call the callback onFile for each file that exists within them passing in the
            // parent dir name

            IEnumerable<IListBlobItem> languages = root.ListBlobs().Where(
                b => b as CloudBlobDirectory != null
            );

            foreach (var language in languages) 
            {
                // For each subdir of 'keywords'
                IEnumerable<IListBlobItem> files = ((CloudBlobDirectory)language).ListBlobs();
                if (files.Count() > 0) 
                {
                    var lang = language.Uri.Segments.Last();
                    if (lang.Last() == '/') {
                        lang = lang.Remove(lang.Length - 1);
                    }

                    foreach (var file in files) 
                    {
                        if (!(file is CloudBlob)) {
                            continue;
                        }

                        // Callback
                        onFile(file as CloudBlob, lang);
                    }
                }
            }
        }

        private static Dictionary<string, Dictionary<string, Geo>> LoadLocationInferenceDictionary(
            CloudBlobDirectory locationsRoot)
        {
            var locationDictionary = new Dictionary<string, Dictionary<string, Geo>>();

            TraverseReferenceData(locationsRoot, (file, lang) => {

                if (!locationDictionary.ContainsKey(lang)) {
                    locationDictionary[lang] = new Dictionary<string, Geo>();
                }

                var locations = locationDictionary[lang];
                using (var rd = new StreamReader(file.OpenRead()))
                {
                    while (!rd.EndOfStream)
                    {
                        var splits = rd.ReadLine().Split(',');

                        if (splits.Length == 3)
                        {
                            string city = splits[0].ToLower();
                            locations[city] = new Geo()
                            {
                                Lat = Double.Parse(splits[1].Trim(), CultureInfo.InvariantCulture),
                                Lon = Double.Parse(splits[2].Trim(), CultureInfo.InvariantCulture)
                            };
                        }
                    }
                }
            });

            return locationDictionary;
        }

        private static Dictionary<string, HashSet<string>> LoadKeywords(CloudBlobDirectory keywordsRoot)
        {
            var keywords = new Dictionary<string, HashSet<string>>();

            TraverseReferenceData(keywordsRoot, (file, lang) => {
               
                if (!keywords.ContainsKey(lang)) {
                    keywords[lang] = new HashSet<string>();
                }

                var keywordSet = keywords[lang];
                using (var rd = new StreamReader(file.OpenRead()))
                {
                    while (!rd.EndOfStream)
                    {
                        keywordSet.UnionWith(rd.ReadLine().ToLower().Split(',').Select(w => w.Trim()));
                    }
                }
            });

            return keywords;
        }

        /// <summary>
        /// By keyword, return a tuple containing the grouping of keywords mapped to a given category.
        /// </summary>
        private static CategoryMap LoadKeyphraseLists(CloudBlobDirectory root)
        {
            var keyphraseList = new CategoryMap();

            TraverseReferenceData(root, (file, lang) => {
 
                if (!keyphraseList.ContainsKey(lang)) {
                    keyphraseList[lang] = new Dictionary<string, Tuple<List<string>, string>>();
                }

                using (var rd = new StreamReader(file.OpenRead()))
                {
                    while (!rd.EndOfStream)
                    {
                        var splits = rd.ReadLine().ToLower().Split(',').Select(w => w.Trim()).ToArray();

                        // Input is a .csv of the form:
                        // category (english), [keyword(english), keyword(other), ...]
                        // where other language is identified iby the parent directory 
                        // which whould be the iso639-2 two letter language code (e.g. ar = arabic)

                        var category = splits[0];
                        List<string> phrase = new List<string>();
                        for (var i = 1; i < splits.Length; i++) {
                            phrase.Add(splits[i]);
                        }

                        var tuple = Tuple.Create(phrase, category);
                      
                        foreach (var kw in phrase)
                        {
                            keyphraseList[lang][kw] = tuple;
                        }
                    }
                }
            });

            return keyphraseList;
        }

        private static Sources GetSource(string source)
        {
            switch (source?.ToLower())
            {
                case RSS_ID_STR:
                    return Sources.RSS;
                case TWITTER_ID_STR:
                    return Sources.TWITTER;
                case FB_MSG_ID_STR:
                    return Sources.FB_MESSAGES;
                case FB_CMT_ID_STR:
                    return Sources.FB_COMMENTS;
                default:
                    return Sources.TWITTER;
            }
        }

        private static GeoJSONObject InfereLocationFromContent(string language, string word)
        {
            if (!locationInferenceDictionary.ContainsKey(language)) {
                // We don't have any location info for this language
                return null;
            }

            if ((word.Length >= 2))
            {
                string lowerWord = word.ToLower();

                foreach (var locationEntry in locationInferenceDictionary[language])
                {
                    if (IsFuzzyMatch(locationEntry.Key, lowerWord))
                    {
                        var loc = locationEntry.Value;
                        return new Point(new GeographicPosition(loc.Lat, loc.Lon));
                    }
                }
            }
            return null;
        }

        private static bool IsFuzzyMatch(string source, string target)
        {
            bool isMatch = source.Equals(target);

            if (!isMatch)
            {
                string substring = source.LongestCommonSubstring(target);
                if (substring.Length > 0)
                {
                    double normalizedSubstringMin = 1 - Convert.ToDouble((substring.Length) / Convert.ToDouble(Math.Min(source.Length, target.Length)));
                    double normalizedSubstringMax = 1 - Convert.ToDouble((substring.Length) / Convert.ToDouble(Math.Max(source.Length, target.Length)));

                    if ((normalizedSubstringMin < 0.2) && (normalizedSubstringMax < 0.2))
                    {
                        double jwDist = Convert.ToDouble(1 - source.JaroWinklerDistance(target));
                        Trace.TraceInformation(" FuzzyMatch source: {0} target: {1} dist: {2}", source, target, jwDist);
                        if (jwDist < 0.5)
                        {
                            isMatch = true;
                        }
                    }
                }
            }
            if (isMatch)
            {
                Trace.TraceInformation("Matched source: {0} target: {1} ", source, target);
            }
            return isMatch;
        }

        public static List<ReferencedLocation> GetGeoLocations(
            string possibleLocationStr, bool isGeoJson, IEnumerable<string> words, string language)
        {
            /* We're going to try and assign a location to data streams arriving from a variety of
             * sources, some of which are geo-tagged already some of which we're going to infer
             * by other methods.
             */

            List<ReferencedLocation> locations = new List<ReferencedLocation>();
            var wasTagged = !string.IsNullOrWhiteSpace(possibleLocationStr);
            // If there's anything in the existing geo field
            if (wasTagged)
            {
                if (isGeoJson)
                {
                    // geo field is flagged as being standard geojson
                    if ((possibleLocationStr == "") || (possibleLocationStr == "{}"))
                        // .. but there's nothing there.
                        wasTagged = false;
                    else
                    {
                        try
                        {
                            // Directly transfer the geo information that already exists
                            locations.Add(new ReferencedLocation
                            {
                                Location = JsonConvert.DeserializeObject<Point>(possibleLocationStr),
                                InferenceType = "Tagged",
                                Probability = 1.0f // We implicitly trust the prior geotagging
                            });
                        }
                        catch (Exception e)
                        {
                            // Doesn't look like standard geojson
                            Trace.TraceError("Failed to parse location: {0}: {1}", possibleLocationStr, e);
                            wasTagged = false;
                        }
                    }
                }
                else
                {
                    try
                    {
                        // There's something in the geo field but it's not standard geojson
                        GeoJSONObject geoJson = InfereLocationFromContent(language, possibleLocationStr);
                        if (geoJson != null)
                        {
                            locations.Add(new ReferencedLocation
                            {
                                Location = geoJson,
                                InferenceType = "UserTagged",
                                Probability = 1.0f // Hmmm
                            });
                        }
                        else 
                        {
                            wasTagged = false;
                        }
                    }
                    catch (Exception e)
                    {
                        Trace.TraceError("Failed to get location: {0}: {1}", possibleLocationStr, e);
                        wasTagged = false;
                    }
                }
            }

            if (!wasTagged)
            {
                // No geo tag provided see what we can infer from the
                // message content
                foreach (string word in words)
                {
                    var geoJsonLocation = InfereLocationFromContent(language, word);
                    if (geoJsonLocation != null)
                    {
                        locations.Add(new ReferencedLocation
                        {
                            Location = geoJsonLocation,
                            // it's not tagged as we inferred the location
                            InferenceType = "Content",
                            Probability = 1.0f
                        });
                    }
                }
            }

            return locations;
        }

        // Given a set of words, fuzzily match against our keyword list for the given
        // language
        public static List<string> GetKeywordsForWords(string language, IEnumerable<string> words)
        {
            if (!keywordLists.ContainsKey(language)) {
                // Return empty list if we don't have a keyword list for this
                // language
                return new List<string>();
            }

            var matched = new List<string>();

            try
            {
                /*
                foreach (string word in words)
                {
                    if ((word != null) && (word.Length >=2))
                    { 
                        string lowerWord = word.ToLower();

                        foreach (var keyword in keywordLists[language])
                        {
                            if (IsFuzzyMatch(keyword, lowerWord))
                            {
                                matched.Add(keyword);
                            }
                        }
                    }
                }
                */
                var wordsArray = words.ToArray();
                for (int i=0; i < wordsArray.Length; i++)
                {
                    foreach (var keyword in keywordLists[language])
                    {
                        var spaceCount = keyword.Where(x => x == ' ').Count();
                        string lowerWord = wordsArray[i].ToLower();

                        // in the case of a keyword that contains spaces, we need to construct the word using it's neighboring tokens
                        if (spaceCount > 0)
                        {
                            if ((spaceCount + i) < wordsArray.Length)
                            {

                                for (int j = 1; j <= spaceCount; j++)
                                {
                                    lowerWord = string.Format("{0} {1}", lowerWord, wordsArray[j].ToLower());
                                }
                            }
                        }
                        if (lowerWord != null)
                        {
                            if (lowerWord.Equals(keyword))
                            {
                                matched.Add(keyword);
                            }
                            else if (IsFuzzyMatch(keyword, lowerWord))
                            {
                                matched.Add(keyword);
                            }
                        }
                    }
                }
            }
            catch (Exception) { }
            return matched;
        }

        public static CloudTable GetUsersTable()
        {
            return usersTable;
        }
        public static List<string> GetSectorsForWords(string language, IEnumerable<string> tokens)
        {
            var rc = new List<string>();
            if (sectorsByKeyword.ContainsKey(language))
            {
                var sectorKeywords = sectorsByKeyword[language];
                rc = GetCategoriesForTokens(tokens, sectorKeywords).ToList();
            }
            return rc;
        }

        public static List<string> GetGroupsForWords(string language, IEnumerable<string> tokens)
        {
            var rc = new List<string>();
            if (groupsByKeyword.ContainsKey(language))
            {
                var groups = groupsByKeyword[language];
                rc = GetCategoriesForTokens(tokens, groups).ToList();
            }
            return rc;
        }

        public static List<string> GetStatusesForWords(string language, IEnumerable<string> tokens)
        {
            var rc = new List<string>();
            if (statusesByKeyword.ContainsKey(language))
            {
                var statuses = statusesByKeyword[language];
                rc = GetCategoriesForTokens(tokens, statuses).ToList();
            }
            return rc;
        }

        private static HashSet<string> GetCategoriesForTokens(
            IEnumerable<string> tokens, Dictionary<string, Tuple<List<string>, string>> categoriesByKeyword)
        {
            // HashSet here because it doesn't seem to make much sense to return
            // the same category multiple times

            var results = new HashSet<string>();
            foreach (var tok in tokens)
            {
                Tuple<List<string>, string> curResult;

                // TODO: Should try and pull some sort of "confidence" out of matching multiple kws in the set.
                // TODO: "like"-ness or lemmatized matching
                if (categoriesByKeyword.TryGetValue(tok, out curResult))
                {
                    results.Add(curResult.Item2);
                }
            }

            return results;
        }
    }
}
