# Fortis
Fortis implements a pipeline to observe domain related Twitter streams across time and location. 
It leverages the Twitter streaming api by filtering on a set of keywords, language and a geographical bounding box.
As part of the pipeline, we infere groups (the occurence of a keyword combination) as well as the location for tweets
which haven't been geo-tagged. The final output of the pipeline is an aggregation of keywords and groups across time 
(or other dimensions such as location). 

This pipeline is a useful tool for gathering inteligence. For instance, we used it for better planning the need for humatarian aid or for fighting epidemic diseases 
(such as an outbreak of dengue fever). Infact, the keyword configuration of this repo was used to filter on dengue fever 
related tweets within Indonesia and Sri Lanka. We then aggregated the data across time and location and visualized it 
as part of a research board.

## Configure and deploy the pipeline
First step is to configure the keywords and groups. Simply updated the files into the respective folder ( [Data/refdata/keywords](./Data/refdata/keywords) or [Data/refdata/groups](./Data/refdata/groups)) by creating a directory for each language using the iso639-2 two letter language code (e.g. ar = arabic):
English keywords would be placed in  [Data\refdata\keywords\en](tree/master/Data/refdata/keywords/en) and French keywords in  [Data/refdata/keywords/fr](./Data/refdata/keywords/fr)
The same applies for the definition of groups.

1. The keyword configuration is a .csv of the form: ``[keyword(english), keyword(other), ...]`` where other language is identified by the parent directory
2. The group configuration is a .csv of the form: ``category (english), [keyword(english), keyword(other), ...]`` 

Once you configured the keywords and groups, you should obtain the Twitter tokens by creating a new app [here](https://apps.twitter.com/)
As the final preperation, you need to obtain the bounding box for the geo-filtering of tweets:
e.g. here the rough bounding box for Indonesia and Sri Lanka ``"19.938716 , 8.948158, 32.938335,25.129859"``

Finally, navigate to  [Deployment/Scripts](./Deployment/Scripts) and open your PowerShell in elevated mode and execute  ``Deploy-FortisServices`` : 

```
.\Deploy-FortisServices `
    -SubscriptionId <YOUR_AZURE_SUBSCRIPTION_ID> `
    -DeploymentPostFix <YOUR_UNIQUE_ID> `
    -ResourceGroupName <YOUR_RESOURCE_GROUP_NAME> `
    -Location "West Europe" `
    -TwitterConsumerKey <YOUR_TOKEN> `
    -TwitterConsumerSecret <YOUR_TOKEN>  `
    -TwitterAccessTokenKey <YOUR_TOKEN>  `
    -TwitterAccessTokenSecret <YOUR_TOKEN>  `
    -BoundingBox <YOUR_BOUNDING_BOX> `
    -LanguageFilter "YOUR_LANGUAGE_FILTER" `
    -SparkFilter "*/*/*/*/*.json" `
    -HdiPassword <YOUR_STRONG_HDI_CLUSTER_PASSWORD>  `
    -DeploySites $true
```
The above script creates all required Azure resources and deployes all services. An overview of the architecture is here:
![fortis trend pipeline](./images/FortisTrendPipeline.jpg "Fortis trend pipeline")



