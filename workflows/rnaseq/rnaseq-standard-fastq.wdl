## # RNA-Seq Standard from FASTQ
##
## An example input JSON entry for `read_groups` might look like this:
## {
##     ...
##     "rnaseq_standard_fastq.read_groups": [
##         {
##             "ID": "rg1",
##             "PI": 150,
##             "PL": "ILLUMINA",
##             "SM": "Sample",
##             "LB": "Sample"
##         }
##     ],
##     ...
## }
#
# SPDX-License-Identifier: MIT
# Copyright St. Jude Children's Research Hospital
version 1.1

import "../../tools/fq.wdl"
import "./rnaseq-core.wdl" as rnaseq_core_wf
import "./rnaseq-standard.wdl" as rnaseq_standard

workflow rnaseq_standard_fastq {
    meta {
        description: "Runs the STAR RNA-Seq alignment workflow for St. Jude Cloud from FASTQ input"
        outputs: {
            bam: "Harmonized RNA-Seq BAM"
            bam_index: "BAI index file associated with `bam`"
            bam_checksum: "STDOUT of the `md5sum` command run on the harmonized BAM that has been redirected to a file"
            star_log: "Summary mapping statistics after mapping job is complete"
            bigwig: "BigWig format coverage file generated from `bam`"
            feature_counts: "A two column headerless TSV file. First column is feature names and second column is counts."
            inferred_strandedness: "TSV file containing the `ngsderive strandedness` report"
            inferred_strandedness_string: "Derived strandedness from `ngsderive strandedness`"
        }
    }

    parameter_meta {
        gtf: "Gzipped GTF feature file"
        star_db: "Database of reference files for the STAR aligner. The name of the root directory which was archived must match the archive's filename without the `.tar.gz` extension. Can be generated by `star-db-build.wdl`"
        read_one_fastqs_gz: "Input gzipped FASTQ format file(s) with 1st read in pair to align"
        read_two_fastqs_gz: "Input gzipped FASTQ format file(s) with 2nd read in pair to align"
        read_groups: {
            description: "An Array of structs defining read groups to include in the harmonized BAM. Must correspond to input FASTQs. Each read group ID must be contained in the basename of a FASTQ file or pair of FASTQ files if Paired-End. This requirement means the length of `read_groups` must equal the length of `read_one_fastqs_gz` and the length of `read_two_fastqs_gz` if non-zero. Only the `ID` field is required, and it must be unique for each read group defined. See top of file for help formatting your input JSON."  # TODO handle unknown RG case
            external_help: "https://samtools.github.io/hts-specs/SAMv1.pdf"
            fields: {
                ID: "Read group identifier. Each Read Group must have a unique ID. The value of ID is used in the RG tags of alignment records."
                BC: "Barcode sequence identifying the sample or library. This value is the expected barcode bases as read by the sequencing machine in the absence of errors. If there are several barcodes for the sample/library (e.g., one on each end of the template), the recommended implementation concatenates all the barcodes separating them with hyphens (`-`)."
                CN: "Name of sequencing center producing the read."
                DS: "Description."
                DT: "Date the run was produced (ISO8601 date or date/time)."
                FO: "Flow order. The array of nucleotide bases that correspond to the nucleotides used for each flow of each read. Multi-base flows are encoded in IUPAC format, and non-nucleotide flows by various other characters. Format: /\*|[ACMGRSVTWYHKDBN]+/"
                KS: "The array of nucleotide bases that correspond to the key sequence of each read."
                LB: "Library."
                PG: "Programs used for processing the read group."
                PI: "Predicted median insert size, rounded to the nearest integer."
                PL: "Platform/technology used to produce the reads. Valid values: CAPILLARY, DNBSEQ (MGI/BGI), ELEMENT, HELICOS, ILLUMINA, IONTORRENT, LS454, ONT (Oxford Nanopore), PACBIO (Pacific Biosciences), SINGULAR, SOLID, and ULTIMA. This field should be omitted when the technology is not in this list (though the PM field may still be present in this case) or is unknown."
                PM: "Platform model. Free-form text providing further details of the platform/technology used."
                PU: "Platform unit (e.g., flowcell-barcode.lane for Illumina or slide for SOLiD). Unique identifier."
                SM: "Sample. Use pool name where a pool is being sequenced."
            }
        }
        prefix: "Prefix for output files"
        contaminant_db: "A compressed reference database corresponding to the aligner chosen with `xenocp_aligner` for the contaminant genome"
        max_retries: "Number of times to retry failed steps. Overrides task level defaults."
        xenocp_aligner: {
            description: "Aligner to use to map reads to the host genome for detecting contamination"
            choices: [
                'bwa aln',
                'bwa mem',
                'star'
            ]
        },
        strandedness: {
            description: "Strandedness protocol of the RNA-Seq experiment. If unspecified, strandedness will be inferred by `ngsderive`."
            choices: [
                '',
                'Stranded-Reverse',
                'Stranded-Forward',
                'Unstranded'
            ]
        },
        mark_duplicates: "Add SAM flag to computationally determined duplicate reads?"
        cleanse_xenograft: "Use XenoCP to unmap reads from contaminant genome?"
        validate_input: "Ensure input FASTQs are well-formed before beginning harmonization?"
        use_all_cores: "Use all cores for multi-core steps?"
        subsample_n_reads: "Only process a random sampling of `n` reads. Any `n`<=`0` for processing entire input."
    }

    input {
        File gtf
        File star_db
        Array[File] read_one_fastqs_gz
        Array[File] read_two_fastqs_gz
        Array[ReadGroup] read_groups
        String prefix
        File? contaminant_db
        Int? max_retries
        String xenocp_aligner = "star"
        String strandedness = ""
        Boolean mark_duplicates = false
        Boolean cleanse_xenograft = false
        Boolean validate_input = true
        Boolean use_all_cores = false
        Int subsample_n_reads = -1
    }

    call rnaseq_standard.parse_input { input:
        input_strand=strandedness,
        cleanse_xenograft=cleanse_xenograft,
        contaminant_db=defined(contaminant_db)
    }

    scatter (rg in read_groups) {
        call ReadGroup_to_string { input: read_group=rg, max_retries=max_retries }
    }
    String stringified_read_groups = sep(
        ' , ', ReadGroup_to_string.stringified_read_group
    )

    if (validate_input){
        scatter (reads in zip(read_one_fastqs_gz, read_two_fastqs_gz)) {
            call fq.fqlint { input:
                read_one_fastq=reads.left,
                read_two_fastq=reads.right,
                max_retries=max_retries
            }
        }
    }

    if (subsample_n_reads > 0) {
        Int reads_per_pair = ceil(subsample_n_reads / length(read_one_fastqs_gz))
        scatter (reads in zip(read_one_fastqs_gz, read_two_fastqs_gz)) {
            call fq.subsample { input:
                read_one_fastq=reads.left,
                read_two_fastq=reads.right,
                record_count=reads_per_pair,
                max_retries=max_retries
            }
        }
    }
    Array[File] selected_read_one_fastqs = select_first([
        subsample.subsampled_read1,
        read_one_fastqs_gz
    ])
    Array[File] selected_read_two_fastqs = select_all(
        select_first([
            subsample.subsampled_read2,
            read_two_fastqs_gz
        ])
    )

    call rnaseq_core_wf.rnaseq_core { input:
        read_one_fastqs_gz=selected_read_one_fastqs,
        read_two_fastqs_gz=selected_read_two_fastqs,
        read_groups=stringified_read_groups,
        prefix=prefix,
        gtf=gtf,
        star_db=star_db,
        mark_duplicates=mark_duplicates,
        contaminant_db=contaminant_db,
        cleanse_xenograft=cleanse_xenograft,
        xenocp_aligner=xenocp_aligner,
        strandedness=strandedness,
        use_all_cores=use_all_cores,
        max_retries=max_retries
    }

    output {
        File bam = rnaseq_core.bam
        File bam_index = rnaseq_core.bam_index
        File bam_checksum = rnaseq_core.bam_checksum
        File star_log = rnaseq_core.star_log
        File bigwig = rnaseq_core.bigwig
        File feature_counts = rnaseq_core.feature_counts
        File inferred_strandedness = rnaseq_core.inferred_strandedness
        String inferred_strandedness_string = rnaseq_core.inferred_strandedness_string
    }
}

# See the `read_groups` `parameter_meta` for definitions of each field
struct ReadGroup {
    String ID
    String? BC
    String? CN
    String? DS
    String? DT
    String? FO
    String? KS
    String? LB
    String? PG
    Int? PI
    String? PL
    String? PM
    String? PU
    String? SM
}

task ReadGroup_to_string {
    meta {
        description: "Stringifies a ReadGroup struct"
        outputs: {
            stringified_read_group: "Input ReadGroup as a string"
        }
    }

    parameter_meta {
        read_group: "ReadGroup struct to stringify"
        memory_gb: "RAM to allocate for task, specified in GB"
        disk_size_gb: "Disk space to allocate for task, specified in GB"
        max_retries: "Number of times to retry in case of failure"
    }

    input {
        ReadGroup read_group
        Int memory_gb = 4
        Int disk_size_gb = 10
        Int max_retries = 1
    }

    command <<<
        {
            echo -n "~{'ID:~{read_group.ID}'}"  # required field. All others optional
            echo -n "~{if defined(read_group.BC) then ' BC:~{read_group.BC}' else ''}"
            echo -n "~{if defined(read_group.CN) then ' CN:~{read_group.CN}' else ''}"
            echo -n "~{if defined(read_group.DS) then ' DS:~{read_group.DS}' else ''}"
            echo -n "~{if defined(read_group.DT) then ' DT:~{read_group.DT}' else ''}"
            echo -n "~{if defined(read_group.FO) then ' FO:~{read_group.FO}' else ''}"
            echo -n "~{if defined(read_group.KS) then ' KS:~{read_group.KS}' else ''}"
            echo -n "~{if defined(read_group.LB) then ' LB:~{read_group.LB}' else ''}"
            echo -n "~{if defined(read_group.PG) then ' PG:~{read_group.PG}' else ''}"
            echo -n "~{if defined(read_group.PI) then ' PI:~{read_group.PI}' else ''}"
            echo -n "~{if defined(read_group.PL) then ' PL:~{read_group.PL}' else ''}"
            echo -n "~{if defined(read_group.PM) then ' PM:~{read_group.PM}' else ''}"
            echo -n "~{if defined(read_group.PU) then ' PU:~{read_group.PU}' else ''}"
            echo "~{if defined(read_group.SM) then ' SM:~{read_group.SM}' else ''}"
        } > out.txt
    >>>

    output {
        String stringified_read_group = read_string("out.txt")
    }

    runtime {
        memory: "~{memory_gb} GB"
        disk: "~{disk_size_gb} GB"
        container: 'ghcr.io/stjudecloud/util:1.3.0'
        maxRetries: max_retries
    }
}
