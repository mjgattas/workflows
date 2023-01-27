## # RNA-Seq Standard
##
## This WDL workflow runs the STAR RNA-seq alignment workflow for St. Jude Cloud.
##
## The workflow takes an input BAM file and splits it into fastq files for each read in the pair. 
## The read pairs are then passed through STAR alignment to generate a BAM file.
## In the case of xenograft samples, the resulting BAM can be optionally cleansed
## with our XenoCP workflow.
## Quantification is done using htseq-count. Coverage is calculated with DeepTools.
## Strandedness is inferred using ngsderive.
## File validation is performed at several steps, including immediately preceeding output.
##
## ## LICENSING
##
## #### MIT License
##
## Copyright 2020-Present St. Jude Children's Research Hospital
##
## Permission is hereby granted, free of charge, to any person obtaining a copy of this
## software and associated documentation files (the "Software"), to deal in the Software
## without restriction, including without limitation the rights to use, copy, modify, merge,
## publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
## to whom the Software is furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in all copies or
## substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
## BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
## NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
## DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

version 1.0

import "https://raw.githubusercontent.com/stjudecloud/workflows/master/workflows/general/bam-to-fastqs.wdl" as b2fq
import "https://raw.githubusercontent.com/stjudecloud/workflows/master/tools/star.wdl"
import "https://raw.githubusercontent.com/stjudecloud/workflows/master/tools/picard.wdl"
import "https://raw.githubusercontent.com/stjudecloud/workflows/master/tools/ngsderive.wdl"
import "https://raw.githubusercontent.com/stjudecloud/workflows/master/tools/htseq.wdl"
import "https://raw.githubusercontent.com/stjudecloud/workflows/master/tools/samtools.wdl"
import "https://raw.githubusercontent.com/stjudecloud/workflows/master/tools/util.wdl"
import "https://raw.githubusercontent.com/stjudecloud/workflows/master/tools/deeptools.wdl"
import "https://raw.githubusercontent.com/stjude/XenoCP/3.1.4/wdl/workflows/xenocp.wdl" as xenocp_workflow

workflow rnaseq_standard {
    input {
        File gtf
        File input_bam
        File stardb_tar_gz
        String strandedness = ""
        String output_prefix = basename(input_bam, ".bam")
        Int subsample_n_reads = -1
        Int max_retries = 1
        Boolean detect_nproc = false
        Boolean validate_input = true
        Boolean cleanse_xenograft = false
        File? contaminant_stardb_tar_gz
    }

    parameter_meta {
        gtf: "GTF feature file"
        input_bam: "Input BAM format file to quality check"
        stardb_tar_gz: "Database of reference files for the STAR aligner. Can be generated by `rnaseq-star-db-build.wdl`"
        strandedness: "empty, 'Stranded-Reverse', 'Stranded-Forward', or 'Unstranded'. If missing, will be inferred"
        output_prefix: "Prefix for output files"
        subsample_n_reads: "Only process a random sampling of `n` reads. <=`0` for processing entire input BAM."
        max_retries: "Number of times to retry failed steps"
        detect_nproc: "Use all available cores for multi-core steps"
        cleanse_xenograft: "For xenograft samples, enable XenoCP cleansing of mouse contamination"
        contaminant_stardb_tar_gz: "If using XenoCP to clean contaminant reads, provide a STAR reference for the contaminant genome"
    }

    String provided_strandedness = strandedness

    call parse_input { input: input_strand=provided_strandedness, cleanse_xenograft=cleanse_xenograft, contaminant_stardb_tar_gz=contaminant_stardb_tar_gz }
    if (validate_input) {
       call picard.validate_bam as validate_input_bam { input: bam=input_bam, max_retries=max_retries }
    }

    if (subsample_n_reads > 0) {
        call samtools.subsample {
            input:
                bam=input_bam,
                max_retries=max_retries,
                desired_reads=subsample_n_reads,
                detect_nproc=detect_nproc
        }
    }
    File selected_input_bam = select_first([subsample.sampled_bam, input_bam])

    call util.get_read_groups { input: bam=selected_input_bam, max_retries=max_retries }
    String read_groups = read_string(get_read_groups.out)
    call b2fq.bam_to_fastqs { input: bam=selected_input_bam, max_retries=max_retries, detect_nproc=detect_nproc }

    call star.alignment {
        input:
            read_one_fastqs=bam_to_fastqs.read1s,
            read_two_fastqs=bam_to_fastqs.read2s,
            stardb_tar_gz=stardb_tar_gz,
            output_prefix=output_prefix,
            read_groups=read_groups,
            max_retries=max_retries,
            detect_nproc=detect_nproc
    }
    call picard.sort as picard_sort { input: bam=alignment.star_bam, max_retries=max_retries }
    call samtools.index as samtools_index { input: bam=picard_sort.sorted_bam, max_retries=max_retries, detect_nproc=detect_nproc }
    call picard.validate_bam { input: bam=picard_sort.sorted_bam, max_retries=max_retries }
    call ngsderive.infer_strandedness as ngsderive_strandedness { input: bam=picard_sort.sorted_bam, bai=samtools_index.bai, gtf=gtf, max_retries=max_retries }
    String parsed_strandedness = read_string(ngsderive_strandedness.strandedness)

    if (cleanse_xenograft){
        File contam_db = select_first([contaminant_stardb_tar_gz, ""])
        call xenocp_workflow.xenocp { input: input_bam=picard_sort.sorted_bam, input_bai=samtools_index.bai, reference_tar_gz=contam_db, aligner="star", skip_duplicate_marking=true }
    }
    File aligned_bam = select_first([xenocp.bam, picard_sort.sorted_bam])
    File aligned_bai = select_first([xenocp.bam_index, samtools_index.bai])

    call md5sum.compute_checksum { input: infile=aligned_bam, max_retries=max_retries }

    call htseq.count as htseq_count { input: bam=aligned_bam, gtf=gtf, provided_strandedness=provided_strandedness, inferred_strandedness=parsed_strandedness, max_retries=max_retries }
    call deeptools.bamCoverage as deeptools_bamCoverage { input: bam=aligned_bam, bai=aligned_bai, max_retries=max_retries }

    output {
        File bam = aligned_bam
        File bam_checksum = compute_checksum.outfile
        File bam_index = aligned_bai
        File star_log = alignment.star_log
        File gene_counts = htseq_count.out
        File inferred_strandedness = ngsderive_strandedness.strandedness_file
        File bigwig = deeptools_bamCoverage.bigwig
    }
}

task parse_input {
    input {
        String input_strand
        Boolean cleanse_xenograft
        File? contaminant_stardb_tar_gz
    }

    Boolean db_defined = defined(contaminant_stardb_tar_gz)

    command {
        if [ -n "~{input_strand}" ] && [ "~{input_strand}" != "Stranded-Reverse" ] && [ "~{input_strand}" != "Stranded-Forward" ] && [ "~{input_strand}" != "Unstranded" ]; then
            >&2 echo "strandedness must be empty, 'Stranded-Reverse', 'Stranded-Forward', or 'Unstranded'"
            exit 1
        fi
        if [ "~{cleanse_xenograft}" == "true" ] && [ "~{db_defined}" == "false" ]
        then
            >&2 echo "contaminant_stardb_tar_gz must be supplied if cleanse_xenograft is specified"
            exit 1
        fi
    }

    runtime {
        disk: "1 GB"
        docker: 'ghcr.io/stjudecloud/util:1.2.0'
    }

    output {
        String input_check = "passed"
    }
}
