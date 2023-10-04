version 1.1

import "../../tools/deeptools.wdl"
import "../../tools/htseq.wdl"
import "../../tools/ngsderive.wdl"
import "../../tools/star.wdl"
import "../general/alignment-post.wdl" as alignment_post_wf

workflow rnaseq_core {
    parameter_meta {
        read_one_fastqs_gz: "Input gzipped FASTQ format file(s) with 1st read in pair to align"
        read_two_fastqs_gz: "Input gzipped FASTQ format file(s) with 2nd read in pair to align"
        gtf: "Gzipped GTF feature file"
        star_db: "Database of reference files for the STAR aligner. The name of the root directory which was archived must match the archive's filename without the `.tar.gz` extension. Can be generated by `star-db-build.wdl`"
        read_groups: "A space-delimited read group record for each read group. Exactly one FASTQ filename must match each read group ID from `read_one_fastqs` and `read_two_fastqs`. Read group fields (Required fields: ID, LB, PL, PU, & SM.) should be space delimited. Read groups should be comma separated, with a space on each side (e.g. ' , '). The ID field must come first for each read group and must match the basename of a FASTQ file (up to the first period). Expected form: `ID:rg1 PU:flowcell1.lane1 SM:sample1 PL:illumina LB:sample1_lib1 , ID:rg2 PU:flowcell1.lane2 SM:sample1 PL:illumina LB:sample1_lib1`"
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
        cleanse_xenograft: "If true, use XenoCP to unmap reads from contaminant genome"
        use_all_cores: "Use all cores for multi-core steps?"
    }

    input {
        Array[File] read_one_fastqs_gz
        Array[File] read_two_fastqs_gz
        File gtf
        File star_db
        String read_groups
        String prefix
        File? contaminant_db
        Int? max_retries
        String xenocp_aligner = "star"
        String strandedness = ""
        Boolean mark_duplicates = false
        Boolean cleanse_xenograft = false
        Boolean use_all_cores = false
    }

    Map[String, String] htseq_strandedness_map = {
        "Stranded-Reverse": "reverse",
        "Stranded-Forward": "yes",
        "Unstranded": "no",
        "Inconclusive": "undefined",
        "": "undefined"
    }

    String provided_strandedness = strandedness

    call star.alignment { input:
        read_one_fastqs_gz=read_one_fastqs_gz,
        read_two_fastqs_gz=read_two_fastqs_gz,
        star_db_tar_gz=star_db,
        prefix=prefix,
        read_groups=read_groups,
        use_all_cores=use_all_cores,
        max_retries=max_retries
    }

    call alignment_post_wf.alignment_post { input:
        bam=alignment.star_bam,
        mark_duplicates=mark_duplicates,
        contaminant_db=contaminant_db,
        cleanse_xenograft=cleanse_xenograft,
        xenocp_aligner=xenocp_aligner,
        use_all_cores=use_all_cores,
        max_retries=max_retries
    }

    call deeptools.bam_coverage as deeptools_bam_coverage { input:
        bam=alignment_post.out_bam,
        bam_index=alignment_post.bam_index,
        use_all_cores=use_all_cores,
        max_retries=max_retries
    }

    call ngsderive.strandedness as ngsderive_strandedness { input:
        bam=alignment_post.out_bam,
        bam_index=alignment_post.bam_index,
        gene_model=gtf,
        max_retries=max_retries
    }

    String htseq_strandedness = if (provided_strandedness != "")
        then htseq_strandedness_map[provided_strandedness]
        else htseq_strandedness_map[ngsderive_strandedness.strandedness]

    call htseq.count as htseq_count { input:
        bam=alignment_post.out_bam,
        gtf=gtf,
        strandedness=htseq_strandedness,
        outfile_name=basename(alignment_post.out_bam, "bam")
            + (if provided_strandedness == "" then ngsderive_strandedness.strandedness else provided_strandedness)
            + ".feature-counts.txt",
        max_retries=max_retries
    }

    output {
        File bam = alignment_post.out_bam
        File bam_index = alignment_post.bam_index
        File bam_checksum = alignment_post.bam_checksum
        File star_log = alignment.star_log
        File bigwig = deeptools_bam_coverage.bigwig
        File feature_counts = htseq_count.feature_counts
        File inferred_strandedness = ngsderive_strandedness.strandedness_file
        String inferred_strandedness_string = ngsderive_strandedness.strandedness
    }
}
