#!/usr/bin/env python

# Merge count tsv file into one table. Modify COMMON_COLUMNS and UNIQUE_COLUMNS for another type of output file.
# author: Jeongbin Park (j.park@dkfz.de)
# input: tsv files generated by 'feqtureCounts_2_FpkmTpm' script
# usage: merge_featurecounts_tables.py TSV [TSV ...]

import sys, os, glob
from collections import OrderedDict

def main(argv):
    tsvs = []
    gndic = {}
    with open(argv[1]) as f:
        for line in f:
            if line[0] == "#": continue
            entries = [e.strip().split() for e in line.strip().split("\t")[-1].split(";")]
            entries_as_dic = { k: v.strip('"') for k, v in filter(lambda e: len(e) == 2, entries)}
            gid = entries_as_dic.get("gene_id", "")
            gname = entries_as_dic.get("gene_name", "")
            if len(gid) > 0 and len(gname) > 0:
                gndic[gid] = gname
    for fn in argv[2:]:
        tsvs += [open(gfn) for gfn in glob.glob(fn)]

    fo = open("%s_%s_featureCounts.count.tsv"%(os.environ['SAMPLE'], os.environ['PID']), "w")

    header = "gene_id\tgene_name"
    for tsv in tsvs:
        tsv.readline() # discard header line
        header += '\t' + ''\t'.join(["_".join(e.split("_")[-3:]) for e in tsv.readline().strip().split("\t")[6:]])

    fo.write("#" + header + '\n')

    while True:
        lines = [tsv.readline().strip().split('\t') for tsv in tsvs]
        if all(line[0] == '' for line in lines):
            break
        elif any(line[0] == '' for line in lines):
            # This should not happen!
            print("Error: number of lines in the input files does not match.")
            exit(1)

        gid = lines[0][0]
        entries = [gid, gndic[gid]]
        for line in lines:
            entries += line[6:]
        fo.write('\t'.join(entries) + '\n')

    fo.close()
    for tsv in tsvs:
        tsv.close()

if __name__ == "__main__":
    main(sys.argv)