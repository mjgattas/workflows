## # Deeptools
##
## This WDL file wraps the [DeepTools](https://deeptools.readthedocs.io/en/develop/index.html) tool.
## DeepTools is a suite of Python tools for analysis of high throughput sequencing analysis.

version 1.0

task bamCoverage {
    meta {
        author: "Andrew Thrasher"
        email: "andrew.thrasher@stjude.org"
        description: "This WDL task generates a BigWig coverage track using bamCoverage from DeepTools (https://deeptools.readthedocs.io/en/develop/index.html)."
    }

    parameter_meta {
        bam: "Input BAM format file to generate coverage for"
        bai: "BAM index file corresponding to the input BAM"
    }

    input {
        File bam
        File bam_index
        String prefix = basename(bam, ".bam")
        Int max_retries = 1
        Int memory_gb = 5
        Int ncpu = 1
        Boolean use_all_cores = false
    }

    Float bam_size = size(bam, "GiB")
    Int disk_size = ceil((bam_size * 4) + 10)
 
    command <<<
        set -euo pipefail
        
        n_cores=~{ncpu}
        if [ "~{use_all_cores}" = "true" ]; then
            n_cores="max"
        fi

        # localize BAM and BAI to CWD
        # some backends prevent writing to the inputs directories
        # to accomodate this, create symlinks in CWD
        CWD_BAM=~{basename(bam)}
        ln -s ~{bam} "$CWD_BAM"
        ln -s ~{bam_index} "$CWD_BAM".bai
 
        bamCoverage --bam "$CWD_BAM" --outFileName ~{prefix}.bw --outFileFormat bigwig --numberOfProcessors "$n_cores"

        rm "$CWD_BAM" "$CWD_BAM".bai
    >>>

    output {
        File bigwig = "~{prefix}.bw"
    }

    runtime {
        cpu: ncpu
        disk: disk_size + " GB"
        memory: memory_gb + " GB"
        docker: 'quay.io/biocontainers/deeptools:3.5.1--pyhdfd78af_1'
        maxRetries: max_retries
    }
} 
