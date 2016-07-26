using GeoJSON.Net;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace KeywordInferenceWebJob
{
    public class ReferencedLocation
    {
        public float Probability { get; set; }
        public string InferenceType { get; set; }

        public GeoJSONObject Location { get; set; }
    }

    class KeywordMessage
    {
        public string Source { get; set; }
        public string Sentence { get; set; }
        public string Language { get; set; }

        public DateTime? Created { get; set; }

        public string Keyword { get; set; }

        public List<ReferencedLocation> Locations { get; set; }
        public void AddLocation(GeoJSONObject location, float probability)
        {
            if (Locations == null)
            {
                Locations = new List<ReferencedLocation>();
            }
            Locations.Add(new ReferencedLocation { Location = location, Probability = probability });
        }

        public bool HasLocations()
        {
            return Locations?.Count > 0;
        }
    }

    class SentenceMessage
    {
        public SentenceMessage()
        {
            this.Keywords = new List<string>();
            this.Sectors = new List<string>();
            this.Groups = new List<string>();
            this.Locations = new List<ReferencedLocation>();
            this.Statuses = new List<string>();
        }

        /// <summary>
        /// Should allow mapping back to message in table storage.
        /// </summary>
        public string MessageId { get; set; }

        public string Source { get; set; }
        public string Sentence { get; set; }
        public string Language { get; set; }

        public DateTime? Created { get; set; }

        /// <summary>
        /// Keyword(s) occuring in the message.
        /// </summary>
        public List<string> Keywords { get; set; }

        /// <summary>
        /// Sector(s) that this keyword (or, potentially, keyphrase/key-ngram) belongs to. E.g. Food Security
        /// </summary>
        public List<string> Sectors { get; set; }
        /// <summary>
        /// Group that this keyword (or, potentially, keyphrase/key-ngram) belongs to. E.g. Children
        /// </summary>
        public List<string> Groups { set; get; }
        /// <summary>
        /// Status that this keyword (or, potentially, keyphrase/key-ngram) belongs to. E.g. Asylum seekers
        /// </summary>
        public List<string> Statuses { get; set; }

        public List<ReferencedLocation> Locations { get; set; }
        public void AddLocation(GeoJSONObject location, float probability)
        {
            if (Locations == null)
            {
                Locations = new List<ReferencedLocation>();
            }
            Locations.Add(new ReferencedLocation { Location = location, Probability = probability });
        }

        public bool HasLocations()
        {
            return Locations?.Count > 0;
        }
    }
}
