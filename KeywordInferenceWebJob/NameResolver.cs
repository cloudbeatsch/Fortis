using Microsoft.Azure.WebJobs;
using System.Configuration;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace KeywordInferenceWebJob
{
    public class NameResolver : INameResolver
    {
        public string Resolve(string name)
        {
            return ConfigurationManager.AppSettings[name].ToString();
        }
    }
}
