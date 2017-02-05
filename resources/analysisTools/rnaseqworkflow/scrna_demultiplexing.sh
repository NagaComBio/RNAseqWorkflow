#!/usr/bin/env bash

set -vx

source $CONFIG_FILE
source $TOOL_NAV_LIB

if [ "$RUN_SC_PREPROCESSING" == true ]; then
    JE_PARAMS="BARCODE_READ_POS=READ_1 BARCODE_FOR_SAMPLE_MATCHING=BOTH REDUNDANT_BARCODES=true STRICT=false MAX_MISMATCHES=1 MIN_MISMATCH_DELTA=1 MIN_BASE_QUALITY=10 XTRIMLEN=0 ZTRIMLEN=0 CLIP_BARCODE=true ADD_BARCODE_TO_HEADER=false QUALITY_FORMAT=Standard OUTPUT_DIR=jemultiplexer_out KEEP_UNASSIGNED_READ=true FORCE=true    UNASSIGNED_FILE_NAME_1=unassigned_1.txt UNASSIGNED_FILE_NAME_2=unassigned_2.txt METRICS_FILE_NAME=jemultiplexer_out_stats.txt GZIP_OUTPUTS=true WRITER_FACTORY_USE_ASYNC_IO=true STATS_ONLY=false VERBOSITY=INFO QUIET=false VALIDATION_STRINGENCY=STRICT COMPRESSION_LEVEL=5 MAX_RECORDS_IN_RAM=500000 CREATE_INDEX=false CREATE_MD5_FILE=false"

    check_or_die "$JEMULTIPLEXER_JAR" demultiplexing
    BARCODE_FILE=$(dirname "$READ_LEFT")/barcode.txt
    echo_run "java -jar $JEMULTIPLEXER_JAR FASTQ_FILE1=$READ_LEFT FASTQ_FILE2=$READ_RIGHT BARCODE_FILE=$BARCODE_FILE $JE_PARAMS"
fi
