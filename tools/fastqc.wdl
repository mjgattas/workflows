## [Homepage](https://www.bioinformatics.babraham.ac.uk/projects/fastqc/)
#
# SPDX-License-Identifier: MIT
# Copyright St. Jude Children's Research Hospital
version 1.1

task fastqc {
    meta {
        description: "Generates a FastQC quality control metrics report for the input BAM file"
        outputs: {
            raw_data: "A zip archive of raw FastQC data. Can be parsed by MultiQC."
            results: "A gzipped tar archive of all FastQC output files"
        }
    }

    parameter_meta {
        bam: "Input BAM format file to run FastQC on"
        prefix: "Prefix for the FastQC results directory. The extension `.tar.gz` will be added."
        use_all_cores: "Use all cores? Recommended for cloud environments. Not recommended for cluster environments."
        ncpu: "Number of cores to allocate for task"
        memory_gb: "RAM to allocate for task, specified in GB"
        modify_disk_size_gb: "Add to or subtract from dynamic disk space allocation. Default disk size is determined by the size of the inputs. Specified in GB."
        max_retries: "Number of times to retry in case of failure"
    }

    input {
        File bam
        String prefix = basename(bam, ".bam") + ".fastqc_results"
        Boolean use_all_cores = false
        Int ncpu = 1
        Int memory_gb = 4
        Int modify_disk_size_gb = 0
        Int max_retries = 1
    }

    String out_tar_gz = prefix + ".tar.gz"

    Float bam_size = size(bam, "GiB")
    Int disk_size_gb = ceil(bam_size * 2) + 10 + modify_disk_size_gb

    command <<<
        set -euo pipefail
        
        n_cores=~{ncpu}
        if ~{use_all_cores}; then
            n_cores=$(nproc)
        fi
        
        mkdir ~{prefix}
        fastqc -f bam \
            -o ~{prefix} \
            -t "$n_cores" \
            ~{bam}

        tar -czf ~{out_tar_gz} ~{prefix}
    >>>

    output {
        File raw_data = "~{prefix}/~{basename(bam, '.bam')}_fastqc.zip"  # TODO verify this works if prefix differs
        File results = out_tar_gz
    }

    runtime {
        cpu: ncpu
        memory: "~{memory_gb} GB"
        disk: "~{disk_size_gb} GB"
        container: 'quay.io/biocontainers/fastqc:0.11.9--hdfd78af_1'
        maxRetries: max_retries
    }
}
