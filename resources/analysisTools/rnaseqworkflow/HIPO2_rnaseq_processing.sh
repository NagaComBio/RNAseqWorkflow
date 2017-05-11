#!/usr/bin/env bash

set -vx

##################################################################
##								##
##  HIPO2 RNAseq workflow					##
##  Authors: Naveed Ishaque, Barbara Hutter, Sebastian Uhrig	##
##								##
##################################################################

# TODO : 21/03/2017 : a : (a.1) parse read length, (a.2) specificy sbjdOverhang based on read length and (a.2) pick appropiate genome index
# TODO : 21/03/2017 : b : (b.1) parse strand specificity from RNAseQC, (b.2) only compute read counts for the correct direction using feature counts

##################################################################
##								##
##			   SETUP ENV				##
##								##
##################################################################

source $CONFIG_FILE

source $TOOL_NAV_LIB

echo_run $DO_FIRST

##
## SOFTWARE STACK : load module # module load HIPO2_rna/v1 # loads default software versions for the HIPO2 RNAseq workflow
##

if [ "$LOAD_MODULE" == true ]
then
	module load $MODULE_ENV

	STAR_BINARY=STAR
	FEATURECOUNTS_BINARY=featureCounts
	SAMBAMBA_BINARY=sambamba
	SAMTOOLS_BINARY=samtools # samtools_bin defaults to v0.0.19 despite the RNAseq.XML!!!!!!!!!!!!!!!!!!!!!!!!!!
	RNASEQC_BINARY=rnaseqc
	KALLISTO_BINARY=kallisto
	QUALIMAP_BINARY=qualimap
	ARRIBA_BINARY=arriba
	ARRIBA_READTHROUGH_BINARY=extract_read-through_fusions
	ARRIBA_DRAW_FUSIONS=draw_fusions.R
fi

# Check software stack before running workflow
check_executable "$STAR_BINARY"
check_executable "$FEATURECOUNTS_BINARY"
check_executable "$SAMBAMBA_BINARY"
check_executable "$SAMTOOLS_BINARY"
check_executable "$RNASEQC_BINARY"
check_executable "$KALLISTO_BINARY"
check_executable "$QUALIMAP_BINARY"
check_executable "$ARRIBA_BINARY"
check_executable "$ARRIBA_READTHROUGH_BINARY"
check_executable "$ARRIBA_DRAW_FUSIONS"

########################################################################
##								    ##
##			   WORK FLOW				##
##								    ##
########################################################################

set -u

#make_directory $RESULTS_PID_DIR

##
## PRINT env
##

env | sort > $DIR_EXECUTION/${PBS_JOBNAME}.env_dump.txt

##
## STAR 2-PASS ALIGNMENT: 12 core, 50Gb, 6 hours
##

make_directory $SCRATCH

if [ "$RUN_STAR" == true ]
then
	make_directory $ALIGNMENT_DIR
	cd $ALIGNMENT_DIR
	## the STAR temp directory must not exist, otherwise STAR will fail
	remove_directory $SCRATCH/${SAMPLE}_${pid}_STAR
	echo_run "${STAR_BINARY} ${STAR_PARAMS} --readFilesIn ${READS_STAR_LEFT} ${READS_STAR_RIGHT} --readFilesCommand ${READ_COMMAND} --outSAMattrRGline ${PARM_READGROUPS}"
	check_or_die $STAR_SORTED_BAM alignment
	check_or_die $STAR_NOTSORTED_BAM alignment
	check_or_die $STAR_CHIMERA_SAM alignment
	remove_directory $SCRATCH/${SAMPLE}_${pid}_STAR
	echo_run "mv ${SAMPLE}_${pid}_merged.Chimeric.out.junction ${SAMPLE}_${pid}_chimeric_merged.junction"

	## BAM-erise and sort chimera file: 1 core, 1 hours, 200mb
	echo_run "$SAMTOOLS_BINARY view -Sbh $STAR_CHIMERA_SAM | $SAMTOOLS_BINARY sort - -o $STAR_CHIMERA_BAM_PREF.bam"
	check_or_die ${STAR_CHIMERA_BAM_PREF}.bam chimera-sam-2-bam
	#echo_run "$SAMBAMBA_BINARY markdup -t 1 -l 0 ${STAR_CHIMERA_BAM_PREF}.bam | $SAMTOOLS_BINARY view -h - | $SAMTOOLS_BINARY view -S -b -@ $CORES > ${STAR_CHIMERA_MKDUP_BAM}"
	echo_run "$SAMBAMBA_BINARY markdup -t $CORES ${STAR_CHIMERA_BAM_PREF}.bam ${STAR_CHIMERA_MKDUP_BAM}"
	check_or_die $STAR_CHIMERA_MKDUP_BAM chimera-post-markdups
	remove_file ${STAR_CHIMERA_BAM_PREF}.bam
	echo_run "$SAMBAMBA_BINARY index -t $CORES $STAR_CHIMERA_MKDUP_BAM"
	check_or_die ${STAR_CHIMERA_MKDUP_BAM}.bai chimera-alignment-index

	## markdups using sambamba  (requires 7Gb and 20 min walltime (or 1.5 hrs CPU time) for 200m reads)
	#echo_run "$SAMBAMBA_BINARY markdup -t 1 -l 0 $STAR_SORTED_BAM | $SAMTOOLS_BINARY view -h - | $SAMTOOLS_BINARY view -S -b -@ $CORES > $STAR_SORTED_MKDUP_BAM"
	echo_run "$SAMBAMBA_BINARY markdup -t $CORES $STAR_SORTED_BAM $STAR_SORTED_MKDUP_BAM"
	check_or_die $STAR_SORTED_MKDUP_BAM post-markdups
	
	## index using samtools (requires 40MB and 5 minutes for 200m reads)
	echo_run "$SAMBAMBA_BINARY index -t $CORES $STAR_SORTED_MKDUP_BAM"
	check_or_die ${STAR_SORTED_MKDUP_BAM}.bai alignment-index
	
    ## md5sum
	echo_run "md5sum $STAR_SORTED_MKDUP_BAM | cut -f 1 -d ' ' > $STAR_SORTED_MKDUP_BAM.md5"
	check_or_die ${STAR_SORTED_MKDUP_BAM}.md5 alignment-md5sums
	echo_run "md5sum $STAR_CHIMERA_MKDUP_BAM | cut -f 1 -d ' ' > $STAR_CHIMERA_MKDUP_BAM.md5"
	check_or_die ${STAR_CHIMERA_MKDUP_BAM}.md5 alignment-md5sums

	## flagstats (requires 4MB and 5 minutes for 200m reads)
	echo_run "$SAMBAMBA_BINARY flagstat -t $CORES $STAR_SORTED_MKDUP_BAM > ${STAR_SORTED_MKDUP_BAM}.flagstat"
	check_or_die ${STAR_SORTED_MKDUP_BAM}.flagstat alignment-qc-flagstats
fi

# Run the fingerprinting. This requires the .bai file.
if [[ "${runFingerprinting:-false}" == true ]]
then
        cd $ALIGNMENT_DIR
	echo_run "$PYTHON_BINARY $TOOL_FINGERPRINT $fingerprintingSitesFile $STAR_SORTED_MKDUP_BAM > $STAR_SORTED_MKDUP_BAM.fp.tmp"
	mv "$STAR_SORTED_MKDUP_BAM.fp.tmp" "$STAR_SORTED_MKDUP_BAM.fp"
fi

##
## RNAseQC (requires 10Gb and 6 hours for 200m reads)
##

if [ "$RUN_RNASEQC" == true ]
then
	make_directory $RNASEQC_DIR/${SAMPLE}_${pid}
	cd $RNASEQC_DIR/${SAMPLE}_${pid}
        DOC_FLAG=" "
        if [ "$disableDoC_GATK" == true ]
        then
		DOC_FLAG="-noDoC"
	fi
        echo_run "$RNASEQC_BINARY -r $GENOME_GATK_INDEX $DOC_FLAG -t $GENE_MODELS -n 1000 -o . -s \"${SAMPLE}_${pid}|${ALIGNMENT_DIR}/${STAR_SORTED_MKDUP_BAM}|${SAMPLE}\" &> $DIR_EXECUTION/${PBS_JOBNAME}.${SAMPLE}_${pid}_RNAseQC.log &"
fi

##
## QualiMap2 (requires 6Gb and 3 hours for 200m reads)
##

if [ "$RUN_QUALIMAP" == true ]
then
	make_directory $QUALIMAP_DIR/${SAMPLE}_${pid}
	cd $QUALIMAP_DIR/${SAMPLE}_${pid}
	echo_run "$QUALIMAP_BINARY rnaseq -gtf $GENE_MODELS -s -pe --java-mem-size=60G -outfile ${SAMPLE}_${pid}.report -outdir $QUALIMAP_DIR/${SAMPLE}_${pid} -bam $ALIGNMENT_DIR/$STAR_NOTSORTED_BAM"
	check_or_die rnaseq_qc_results.txt qc-qualimap2
fi

##
## feature Counts htseq like requires 1gb, and 30 min of 4 cores
##

if [ "$RUN_FEATURE_COUNTS" == true ]
then
	make_directory $COUNT_DIR 
	cd $COUNT_DIR
	COUNT="-t exon -g gene_id -p -B -Q 255 -T $CORES -a $GENE_MODELS -F GTF --tmpDir $SCRATCH/${SAMPLE}_${pid}_featureCounts --donotsort"
	make_directory $SCRATCH/${SAMPLE}_${pid}_featureCounts
	for S in {0..2} 
	do
		echo_run "$FEATURECOUNTS_BINARY $COUNT -s $S -o ${SAMPLE}_${pid}.featureCounts.s$S $ALIGNMENT_DIR/$STAR_NOTSORTED_BAM"
		check_or_die ${SAMPLE}_${pid}.featureCounts.s${S} gene-counting
	done
	## RPKM TPM calculations
	echo_run "$TOOL_COUNTS_TO_FPKM_TPM ${SAMPLE}_${pid}.featureCounts.s0 ${SAMPLE}_${pid}.featureCounts.s1 ${SAMPLE}_${pid}.featureCounts.s2 $GENE_MODELS $GENE_MODELS_EXCLUDE > ${SAMPLE}_${pid}.fpkm_tpm.featureCounts.tsv"
	check_or_die ${SAMPLE}_${pid}.fpkm_tpm.featureCounts.tsv counting-featureCounts
	# cleanup
	make_directory ${SAMPLE}_${pid}_featureCounts_raw
	echo_run "mv ${SAMPLE}_${pid}.featureCounts* ${SAMPLE}_${pid}_featureCounts_raw"
	echo_run "tar --remove-files -czvf ${SAMPLE}_${pid}_featureCounts_raw.tgz ${SAMPLE}_${pid}_featureCounts_raw"
	#remove_directory $SCRATCH/${SAMPLE}_${pid}_featureCounts
fi

##
## feature Counts DEXSEQ like
##

if [ "$RUN_FEATURE_COUNTS_DEXSEQ" == true ]
then
	make_directory $COUNT_DIR_EXON
	cd $COUNT_DIR_EXON
	COUNT_EXONS="-f -O -F GTF -a $GENE_MODELS_DEXSEQ -t exonic_part -p -Q 255 -T $CORES --tmpDir $SCRATCH/${SAMPLE}_${pid}_featureCountsExons --donotsort "
	make_directory $SCRATCH/${SAMPLE}_${pid}_featureCountsExons
	for S in {0..2}  
	do
		echo_run "$FEATURECOUNTS_BINARY $COUNT_EXONS -s $S -o ${SAMPLE}_${pid}.featureCounts.dexseq.s$S $ALIGNMENT_DIR/$STAR_NOTSORTED_BAM"
		check_or_die ${SAMPLE}_${pid}.featureCounts.dexseq.s${S} exon-counting
	done
	## RPKM TPM calculations
	echo_run "$TOOL_COUNTSDEXSEQ_TO_FPKM_TPM ${SAMPLE}_${pid}.featureCounts.dexseq.s0 ${SAMPLE}_${pid}.featureCounts.dexseq.s1 ${SAMPLE}_${pid}.featureCounts.dexseq.s2 $GENE_MODELS $GENE_MODELS_EXCLUDE > ${SAMPLE}_${pid}.fpkm_tpm.featureCounts.dexseq.tsv"
	check_or_die ${SAMPLE}_${pid}.fpkm_tpm.featureCounts.dexseq.tsv counting-featureCounts_dexseq
	cleanup
	make_directory ${SAMPLE}_${pid}_featureCounts_dexseq_raw
	echo_run "mv ${SAMPLE}_${pid}.featureCounts* ${SAMPLE}_${pid}_featureCounts_dexseq_raw"
	echo_run "tar --remove-files -czvf ${SAMPLE}_${pid}_featureCounts_dexseq_raw.tgz ${SAMPLE}_${pid}_featureCounts_dexseq_raw"
	#remove_directory $SCRATCH/${SAMPLE}_${pid}_featureCountsExons
fi

##
## Kallisto (2 hours walltime (12 hrs CPU) and 70 gb for 200m reads) PER RUN!
##

KALLISTO_PARAMS="quant -i $GENOME_KALLISTO_INDEX -o . -t $CORES -b 100"
if [ "$RUN_KALLISTO" == true ]
then
	make_directory $KALLISTO_UN_DIR/${SAMPLE}_${pid}
	cd $KALLISTO_UN_DIR/${SAMPLE}_${pid}
	echo_run "$KALLISTO_BINARY $KALLISTO_PARAMS $READS_KALLISTO"
	check_or_die abundance.tsv kallisto
	echo_run "$TOOL_KALLISTO_RESCALE abundance.tsv $GENE_MODELS_EXCLUDE > abundance.rescaled.tsv"
fi

if [ "$RUN_KALLISTO_RF" == true ]
then
	make_directory $KALLISTO_RF_DIR
	cd $KALLISTO_RF_DIR
	$KALLISTO_BINARY $KALLISTO_PARAMS --rf-stranded $READS_KALLISTO
	check_or_die abundance.tsv kallisto
	$TOOL_KALLISTO_RESCALE abundance.tsv $GENE_MODELS_EXCLUDE > abundance.rescaled.tsv
fi

if [ "$RUN_KALLISTO_FR" == true ]
then
	make_directory $KALLISTO_FR_DIR
	cd $KALLISTO_FR_DIR
	$KALLISTO_BINARY $KALLISTO_PARAMS --fr-stranded $READS_KALLISTO
	check_or_die abundance.tsv kallisto
	$TOOL_KALLISTO_RESCALE abundance.tsv $GENE_MODELS_EXCLUDE > abundance.rescaled.tsv
fi

##
## Fusion detection
##

if [ "$RUN_ARRIBA" == true ]
then
	make_directory $ARRIBA_DIR
	cd $ARRIBA_DIR
	echo_run "$ARRIBA_READTHROUGH_BINARY -g $GENE_MODELS -i $ALIGNMENT_DIR/$STAR_SORTED_MKDUP_BAM -o ${SAMPLE}_${pid}_merged_read_through.bam"
	echo_run "$ARRIBA_BINARY -c $ALIGNMENT_DIR/$STAR_CHIMERA_MKDUP_BAM -r ${SAMPLE}_${pid}_merged_read_through.bam -x $ALIGNMENT_DIR/$STAR_SORTED_MKDUP_BAM -a $GENOME_FA -k $ARRIBA_KNOWN_FUSIONS -g $GENE_MODELS -b $ARRIBA_BLACKLIST -o ${SAMPLE}_${pid}.fusions.txt -O ${SAMPLE}_${pid}.discarded_fusions.txt "
	if [[ -f "${SAMPLE}_${pid}.fusions.txt" ]]
	then
		echo_run "$ARRIBA_DRAW_FUSIONS --annotation=$GENE_MODELS --fusions=${SAMPLE}_${pid}.fusions.txt --output=${SAMPLE}_${pid}.fusions.pdf"
	fi
fi

##
## Produce json QC file
##

if [ "$RUN_QCJSON" == true ]
then
	make_directory $QC_DIR
	if [ "$RUN_RNASEQC" == true ]
	then
		echo "# Waiting for RNAseQC"
		wait && cd $QC_DIR
	else
		cd $QC_DIR
	fi
	if [[ -f "$RNASEQC_DIR/${SAMPLE}_${pid}/metrics.tsv" ]]
	then
		echo_run "mv $RNASEQC_DIR/${SAMPLE}_${pid}/metrics.tsv $RNASEQC_DIR/${SAMPLE}_${pid}/${SAMPLE}_${pid}_metrics.tsv"
	fi
	echo_run "$TOOL_CREATE_JSON_FROM_OUTPUT $ALIGNMENT_DIR/${STAR_SORTED_MKDUP_BAM}.flagstat $RNASEQC_DIR/${SAMPLE}_${pid}/${SAMPLE}_${pid}_metrics.tsv > ${JSON_PREFIX}qualitycontrol.json"
	check_or_die ${JSON_PREFIX}qualitycontrol.json qc-json
fi

##
## Clean up files which are no longer needed
##

if [ "$RUN_CLEANUP" == true ]
then
	if [ "$RUN_RNASEQC" == true ]
	then
		echo "# Waiting for RNAseQC"
		wait
	fi
	remove_directory $SCRATCH/*
	remove_file $RNASEQC_DIR/${SAMPLE}_${pid}/refGene.txt*
	remove_file $RNASEQC_DIR/${SAMPLE}_${pid}/rRNA_intervals.list
	if [[ -f "$RNASEQC_DIR/${SAMPLE}_${pid}/${SAMPLE}_${pid}_RNAseQC.tgz" ]]
	then
		echo "# RNAseQC results already archived... skipping"
	else
		echo_run "tar --remove-files -czvf $RNASEQC_DIR/${SAMPLE}_${pid}/${SAMPLE}_${pid}_RNAseQC.tgz $RNASEQC_DIR/${SAMPLE}_${pid}/${SAMPLE}_${pid} "
	fi
	remove_file $ALIGNMENT_DIR/$STAR_SORTED_BAM
	remove_file $ALIGNMENT_DIR/$STAR_NOTSORTED_BAM
	remove_file $ALIGNMENT_DIR/$STAR_CHIMERA_SAM
	remove_file $ALIGNMENT_DIR/*fifo.read1
	remove_file $ALIGNMENT_DIR/*fifo.read2
	make_directory $ALIGNMENT_DIR/${SAMPLE}_${pid}_star_logs_and_files
	echo_run "mv -f $ALIGNMENT_DIR/${SAMPLE}_${pid}*out $ALIGNMENT_DIR/${SAMPLE}_${pid}_star_logs_and_files 2>/dev/null"
	echo_run "mv -f $ALIGNMENT_DIR/${SAMPLE}_${pid}*.tab $ALIGNMENT_DIR/${SAMPLE}_${pid}_star_logs_and_files 2>/dev/null"
	echo_run "mv -f $ALIGNMENT_DIR/${SAMPLE}_${pid}_merged._STARgenome $ALIGNMENT_DIR/${SAMPLE}_${pid}_star_logs_and_files 2>/dev/null"
	echo_run "mv -f $ALIGNMENT_DIR/${SAMPLE}_${pid}_merged._STARpass1 $ALIGNMENT_DIR/${SAMPLE}_${pid}_star_logs_and_files 2>/dev/null"
	remove_directory $SCRATCH
fi

echo "DONE!"
