## # Quality Check Standard
##
## This workflow runs a variety of quality checking software on any BAM file.
## It can be WGS, WES, or Transcriptome data. The results are aggregated and
## run through [MultiQC](https://multiqc.info/).
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

import "../../tools/md5sum.wdl"
import "../../tools/picard.wdl"
import "../../tools/mosdepth.wdl"
import "../../tools/samtools.wdl"
import "../../tools/fastqc.wdl" as fqc
import "../../tools/ngsderive.wdl"
import "../../tools/qualimap.wdl"
import "../../tools/fq.wdl"
import "../../tools/fastq_screen.wdl" as fq_screen
import "../../tools/multiqc.wdl" as mqc
import "../../tools/util.wdl"

workflow quality_check {
    input {
        File bam
        File bam_index
        File reference_fasta
        Array[File] coverage_beds = []
        Array[String] coverage_labels = []
        File? gtf
        File? star_log
        String molecule
        String strandedness = ""
        File? fastq_screen_db
        String phred_encoding = ""
        Boolean paired_end = true
        Int max_retries = 1
    }

    parameter_meta {
        bam: "Input BAM format file to quality check"
        bam_index: "BAM index file corresponding to the input BAM"
        reference_fasta: "Reference genome in FASTA format"
        coverage_beds: "An array of 3 column BEDs which are passed to the `-b` flag of mosdepth, in order to restrict coverage analysis to select regions"
        coverage_labels: "An array of equal length to `coverage_beds` which determines the prefix label applied to the output files. If omitted, defaults of `regions1`, `regions2`, etc. will be used."
        gtf: "GTF features file. **Required** for RNA-Seq data"
        star_log: "Log file generated by the RNA-Seq aligner STAR"
        molecule: "'DNA' or 'RNA'"
        strandedness: "empty, 'Stranded-Reverse', 'Stranded-Forward', or 'Unstranded'. Only needed for RNA-Seq data. If missing, will be inferred"
        fastq_screen_db: "Database for FastQ Screen. **Required** for WGS and WES data. Can be generated using `make-qc-reference.wdl`. Must untar directly to genome directories."
        phred_encoding: "Encoding format used for PHRED quality scores. Must be empty, 'sanger', or 'illumina1.3'. Only needed for WGS/WES. If missing, will be inferred"
        paired_end: "Whether the data is paired end"
        max_retries: "Number of times to retry failed steps"
    }

    String prefix = basename(bam, ".bam")
    String provided_strandedness = strandedness

    call parse_input {
        input:
            input_molecule=molecule,
            input_gtf=gtf,
            input_strand=provided_strandedness,
            input_fq_format=phred_encoding,
            coverage_beds_len=length(coverage_beds),
            coverage_labels=coverage_labels
    }

    call md5sum.compute_checksum { input: infile=bam, max_retries=max_retries }

    call picard.validate_bam { input: bam=bam, succeed_on_errors=true, ignore_list=[], summary_mode=true, max_retries=max_retries }
    call samtools.quickcheck { input: bam=bam, max_retries=max_retries }
    call util.compression_integrity { input: bam=bam, max_retries=max_retries }

    call picard.collect_alignment_summary_metrics { input: bam=quickcheck.checked_bam, max_retries=max_retries }
    call picard.collect_gc_bias_metrics { input: bam=quickcheck.checked_bam, reference_fasta=reference_fasta, max_retries=max_retries }
    call picard.collect_insert_size_metrics { input: bam=quickcheck.checked_bam, max_retries=max_retries }
    call picard.quality_score_distribution { input: bam=quickcheck.checked_bam, max_retries=max_retries }
    call samtools.flagstat as samtools_flagstat { input: bam=quickcheck.checked_bam, max_retries=max_retries }
    call fqc.fastqc { input: bam=quickcheck.checked_bam, max_retries=max_retries }
    call ngsderive.instrument as ngsderive_instrument { input: bam=quickcheck.checked_bam, max_retries=max_retries }
    call ngsderive.read_length as ngsderive_read_length { input: bam=quickcheck.checked_bam, bai=bam_index, max_retries=max_retries }
    
    call ngsderive.encoding as ngsderive_encoding { input: ngs_files=[quickcheck.checked_bam], prefix=prefix, max_retries=max_retries }
    String parsed_encoding = read_string(ngsderive_encoding.inferred_encoding)

    call mosdepth.coverage as wg_coverage {
        input:
            bam=quickcheck.checked_bam,
            bai=bam_index,
            prefix=basename(quickcheck.checked_bam, 'bam')+"whole_genome",
            max_retries=max_retries
    }
    scatter(coverage_pair in zip(coverage_beds, parse_input.labels)) {
        call mosdepth.coverage as regions_coverage {
            input:
                bam=quickcheck.checked_bam,
                bai=bam_index,
                coverage_bed=coverage_pair.left,
                prefix=basename(quickcheck.checked_bam, 'bam')+coverage_pair.right,
                max_retries=max_retries
        }
    }

    if (molecule == "DNA") {
        File fastq_screen_db_defined = select_first([fastq_screen_db, "No DB"])

        call samtools.subsample as samtools_subsample { input: bam=quickcheck.checked_bam, max_retries=max_retries }
        call picard.bam_to_fastq { input: bam=samtools_subsample.sampled_bam, max_retries=max_retries }
        call fq.fqlint { input: read1=bam_to_fastq.read1, read2=bam_to_fastq.read2, max_retries=max_retries }
        call fq_screen.fastq_screen { input: read1=fqlint.validated_read1, read2=select_first([fqlint.validated_read2, ""]), db=fastq_screen_db_defined, provided_encoding=phred_encoding, inferred_encoding=parsed_encoding, max_retries=max_retries }
    }

    if (molecule == "RNA") {
        File gtf_defined = select_first([gtf, "No GTF"])

        call ngsderive.junction_annotation as junction_annotation { input: bam=quickcheck.checked_bam, bai=bam_index, gtf=gtf_defined, max_retries=max_retries }

        call ngsderive.infer_strandedness as ngsderive_strandedness { input: bam=quickcheck.checked_bam, bai=bam_index, gtf=gtf_defined, max_retries=max_retries }
        String parsed_strandedness = read_string(ngsderive_strandedness.strandedness)

        call picard.sort as picard_sort { input: bam=quickcheck.checked_bam, sort_order="queryname", max_retries=max_retries }
        call qualimap.rnaseq as qualimap_rnaseq { input: bam=picard_sort.sorted_bam, gtf=gtf_defined, provided_strandedness=provided_strandedness, inferred_strandedness=parsed_strandedness, name_sorted=true, paired_end=paired_end, max_retries=max_retries }
    }
    
    call mqc.multiqc { input:
        input_files=select_all(flatten([
            [
                validate_bam.out,
                samtools_flagstat.outfile,
                ngsderive_instrument.instrument_file,
                ngsderive_read_length.read_length_file,
                ngsderive_encoding.encoding_file,
                fastqc.raw_data,
                collect_alignment_summary_metrics.alignment_metrics,
                collect_gc_bias_metrics.gc_bias_metrics,
                collect_insert_size_metrics.insert_size_metrics,
                quality_score_distribution.quality_score_distribution_txt,
                wg_coverage.summary,
                wg_coverage.global_dist,
                fastq_screen.raw_data,
                star_log,
                ngsderive_strandedness.strandedness_file,
                junction_annotation.junction_summary,
                qualimap_rnaseq.raw_summary,
                qualimap_rnaseq.raw_coverage
            ],
            regions_coverage.summary,
            regions_coverage.region_dist
        ])),
        output_prefix=basename(bam, '.bam'),
        extra_fn_clean_exts=[".ValidateSamFile"],
        mosdepth_labels=flatten([["whole_genome"], parse_input.labels]),
        max_retries=max_retries
    }

    output {
        File bam_checksum = compute_checksum.outfile
        File validate_sam_file = validate_bam.out
        File flagstat = samtools_flagstat.outfile
        File fastqc_results = fastqc.results
        File instrument_file = ngsderive_instrument.instrument_file
        File read_length_file = ngsderive_read_length.read_length_file
        File inferred_encoding = ngsderive_encoding.encoding_file
        File alignment_metrics = collect_alignment_summary_metrics.alignment_metrics
        File alignment_metrics_pdf = collect_alignment_summary_metrics.alignment_metrics_pdf
        File gc_bias_metrics = collect_gc_bias_metrics.gc_bias_metrics
        File gc_bias_metrics_pdf = collect_gc_bias_metrics.gc_bias_metrics_pdf
        File insert_size_metrics = collect_insert_size_metrics.insert_size_metrics
        File insert_size_metrics_pdf = collect_insert_size_metrics.insert_size_metrics_pdf
        File quality_score_distribution_txt = quality_score_distribution.quality_score_distribution_txt
        File quality_score_distribution_pdf = quality_score_distribution.quality_score_distribution_pdf
        File multiqc_zip = multiqc.out
        File mosdepth_global_dist = wg_coverage.global_dist
        File mosdepth_global_summary = wg_coverage.summary
        Array[File] mosdepth_region_dist = select_all(regions_coverage.region_dist)
        Array[File] mosdepth_region_summary = regions_coverage.summary
        File? fastq_screen_results = fastq_screen.results
        File? inferred_strandedness = ngsderive_strandedness.strandedness_file
        File? qualimap_rnaseq_results = qualimap_rnaseq.results
        File? junction_summary = junction_annotation.junction_summary
        File? junctions = junction_annotation.junctions
    }
}

task parse_input {
    input {
        String input_molecule
        File? input_gtf
        String input_strand
        String input_fq_format
        Int coverage_beds_len
        Array[String] coverage_labels
    }

    String no_gtf = if defined(input_gtf) then "" else "true"

    Int coverage_labels_len = length(coverage_labels)

    command <<<
        EXITCODE=0

        if [ "~{input_molecule}" != "DNA" ] && [ "~{input_molecule}" != "RNA" ]; then
            >&2 echo "molecule input must be 'DNA' or 'RNA'"
            EXITCODE=1
        fi

        if [ "~{input_molecule}" = "RNA" ] && [ "~{no_gtf}" = "true" ]; then
            >&2 echo "Must supply a GTF if molecule = 'RNA'"
            EXITCODE=1
        fi

        if [ -n "~{input_strand}" ] && [ "~{input_strand}" != "Stranded-Reverse" ] && [ "~{input_strand}" != "Stranded-Forward" ] && [ "~{input_strand}" != "Unstranded" ]; then
            >&2 echo "strandedness must be empty, 'Stranded-Reverse', 'Stranded-Forward', or 'Unstranded'"
            EXITCODE=1
        fi

        if [ -n "~{input_fq_format}" ] && [ "~{input_fq_format}" != "sanger" ] && [ "~{input_fq_format}" != "illunima1.3" ]; then
            >&2 echo "phred_encoding must be empty, 'sanger', or 'illumina1.3'"
            EXITCODE=1
        fi

        touch labels.txt
        if [ "~{coverage_labels_len}" = 0 ]; then
            for (( i=1; i<=~{coverage_beds_len}; i++ )); do
                echo regions$i >> labels.txt
            done
        elif [ "~{coverage_labels_len}" != "~{coverage_beds_len}" ]; then
            >&2 echo "Unequal amount of coverage BEDs and coverage labels."
            >&2 echo "If no labels are provided, generic labels will be created."
            >&2 echo "Otherwise the exact same amount must be supplied."
            EXITCODE=1
        else
            echo "~{sep="\n" coverage_labels}" >> labels.txt
        fi

        exit $EXITCODE
    >>>

    runtime {
        memory: "4 GB"
        disk: "5 GB"
        docker: 'ghcr.io/stjudecloud/util:1.2.0'
    }

    output {
        String check = "passed"
        Array[String] labels = read_lines("labels.txt")
    }
}
