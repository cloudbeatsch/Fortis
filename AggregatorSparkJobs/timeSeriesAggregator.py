# -*- coding: utf-8 -*-
"""
Created on Fri Feb 12 09:13:53 2016

@author: noodlefrenzy

Aggregate over groups, sectors, statuses and keywords
 both overall and by tile
"""
from azure.storage.blob import BlobService
from dateutil.parser import parse
import json
import os
from pyspark import SparkConf, SparkContext
import math
import codecs
import shutil
import copy
import datetime
import sys

epoch = datetime.datetime.utcfromtimestamp(0)

# this is the blob container that the Spark job will push the results to.
TIMESERIES_CONTAINER = 'bytimeseries'

def setup_blob_service():    
    blobService = BlobService(account_name=os.environ["STORAGE_ACCOUNT"], account_key=os.environ["STORAGE_KEY"])
    blobService.create_container(TIMESERIES_CONTAINER)
    blobService.set_container_acl(TIMESERIES_CONTAINER, x_ms_blob_public_access='container')
  
    return blobService
    
def unix_time_millis(dt):
    return int((dt - epoch).total_seconds()) * 1000

def by_hour(x):
    created = parse(x['Created'])
    datetime_hour = datetime.datetime(created.year, created.month, created.day, created.hour)
    yield (unix_time_millis(datetime_hour), x)

def build_timespan_label(timespanType, timestampDate):
    month = str(timestampDate.month)
    if len(month) == 1:
        month = "0" + month

    day = str(timestampDate.day)
    if len(day) == 1:
        day = "0" + day

    hour = str(timestampDate.hour)
    if len(hour) == 1:
        hour = "0" + hour

    if timespanType == 'alltime':
        return 'alltime'
    elif timespanType == 'year':
        return 'year-' + str(timestampDate.year)
    elif timespanType == 'month':
        return 'month-' + str(timestampDate.year) + "-" + month
    elif timespanType == 'day':
        return 'day-' + str(timestampDate.year) + "-" + month + "-" + day
    elif timespanType == 'hour':
        return 'hour-' + str(timestampDate.year) + "-" + month + "-" + day + hour + ":00"
        
def matches_timespan(timespan):
    if timespan == 'alltime':
        return lambda x : True
        
    timespanType = timespan[0:timespan.index('-')]
    return lambda sentence : build_timespan_label(timespanType, parse(sentence['Created'])) == timespan

section_map = {
    'Keywords': 'kw-',
    'Sectors': 'sec-',
    'Groups': 'g-',
    'Statuses': 'st-'
}

def println (x):
    print json.dumps(x) + '\n'

def create_agg(topN, merge_value):
    agg = {}
    for top_count in topN:
        top = top_count[0]
        agg[section_map[top[0]] + top[1]] = 0
    return lambda x: merge_value(copy.deepcopy(agg), x)
    
def merge_sentence(topN):
    def merger(agg, s):
        for top_count in topN:
            top = top_count[0]
            if top[1] in s[top[0]]:
                agg[section_map[top[0]] + top[1]] += 1
        return agg
    return merger

def merge_agg(agg1, agg2):
    for key in agg1.keys():
        if key in agg2:
            agg1[key] += agg2[key]
    return agg1

def build_agg(timespan, topN):
    labels = [ "x" ]
    for top_count in topN:
        top = top_count[0]
        labels.append(section_map[top[0]] + top[1])

    def builder(vals_itr):
        agg = {
            'labels': labels,
            'graphData': []
        }
        for val in vals_itr:
            cur = [ val[0] ]
            for label in labels:
                if label in val[1]:
                    cur.append( val[1][label] )
            agg['graphData'].append(cur)
        return agg
    return builder
     
def write_to_file(dirname):
    def writer(kv):
        f = codecs.open(dirname + '/' + kv[0].replace('/', '_') + '.json', 'w', 'utf-8')
        f.write(json.dumps(kv[1], ensure_ascii=False) + '\n')
        f.close()
    return writer

def safe_load(line):
    try:
        return json.loads(line)
    except Exception as e:
        print 'Failed to load "'+line+'\n'
        return {}
        
def get_timespans(x):
    try:
        created = parse(x['Created'])
        for timespanType in ["alltime", "year", "month"]:
            timespanLabel = build_timespan_label(timespanType, created)
            yield timespanLabel
    except Exception:
        print 'Failed to pull "Created" from ' + json.dumps(x, ensure_ascii=False) + '\n'

def has_sections(x):
    slen = lambda a, b: len(a[b]) if b in a else 0
    total_sections = slen(x, 'Keywords') + slen(x, 'Sectors') + slen(x, 'Groups') + slen(x, 'Statuses')
    return total_sections > 0
        
def split_sections(x):
    for k in x['Keywords']:
        yield (('Keywords', k), 1)
    for s in x['Sectors']:
        yield (('Sectors', s), 1)
    for g in x['Groups']:
        yield (('Groups', g), 1)
    for s in x['Statuses']:
        yield (('Statuses', s), 1)
        
def write_to_blob_storage(blobService):
    def writer(kv, blobService=blobService):
        jsonString = json.dumps(kv[1])
        blobService.put_blob(TIMESERIES_CONTAINER, kv[0].replace('/', '_') + '.json', jsonString, "BlockBlob", x_ms_blob_cache_control="max-age=3600", x_ms_blob_content_type="application/json")
    return writer
    
def main(sc):
    # for local runs
    #shutil.rmtree('../Data/spark')
    #lines = sc.textFile("data/large.json")

    blobService = setup_blob_service()
    
    # use the following line for test data
    # lines = sc.textFile("wasb://test-sentences@ochahackfest.blob.core.windows.net/*.json")

    # use the following line to load it from the actual libya storage
    lines = sc.textFile(os.environ["SOURCE_PATH"])
    # lines = sc.textFile("../Data/libya-sentences/*.json")
        
    input_data = lines.map(safe_load).filter(lambda x: has_sections(x) and 'Created' in x)
    input_data.cache()
    # print 'Total applicable records ' + str(input_data.count()) + '\n'
    #input_data.foreach(println)
    
    timespans = input_data.flatMap(get_timespans).distinct().collect()
    for timespan in timespans:
        filtered = input_data.filter(matches_timespan(timespan))
        filtered.cache()

        sectioned = filtered.flatMap(split_sections)
        by_key = sectioned.reduceByKey(lambda a,b: a + b)
        top_5 = by_key.takeOrdered(5, key=lambda x: -x[1])
        
        merger = merge_sentence(top_5)
        creator = create_agg(top_5, merger)
        filtered_by_hour = filtered.flatMap(by_hour)
        #filtered_by_hour.foreach(println)
        
        hourly_counts = filtered_by_hour.combineByKey(creator, merger, merge_agg)
        all_in_one = hourly_counts.sortByKey().groupBy(lambda x: timespan).mapValues(build_agg(timespan, top_5))
        # all_in_one.foreach(write_to_file('../Data/spark'))

        all_in_one.foreach(write_to_blob_storage(blobService))
        # turn into single json payload?
        
        # output hourly counts into timespan file.

'''
{ 
    labels: [ "x", "#refugees", "#women", "#ISIS", "#famine", "benghazi" ],
    graphData: 
[[ new Date("2015/01/01"),930,568,292,390,677 ],
[ new Date("2015/01/02"),184,915,398,993,887 ],
[ new Date("2015/01/03"),336,297,535,730,519 ],
'''

if __name__ == "__main__":
    conf = SparkConf()
    sc = SparkContext(conf=conf)

    os.environ["STORAGE_ACCOUNT"] = str(sys.argv[1])
    os.environ["STORAGE_KEY"] = str(sys.argv[2])
    os.environ["SOURCE_PATH"] = str(sys.argv[3])

    main(sc)

