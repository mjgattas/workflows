## # FQ
##
## This WDL file wraps the [fq tool](https://github.com/stjude/fqlib).
## The fq library provides methods for manipulating Illumina generated 
## FastQ files.

version 1.0

task fqlint {
    meta {
        description: "This WDL task performs quality control on the input FastQ pairs to ensure proper formatting."
    }

    parameter_meta {
        read_one_fastq_gz: "Input FastQ with read one"
        read_two_fastq_gz: "Input FastQ with read two"
    }

    input {
        File read_one_fastq_gz
        File? read_two_fastq_gz
        Int modify_memory_gb = 0
        Int modify_disk_size_gb = 0
        Int max_retries = 1
    }

    Float read1_size = size(read_one_fastq_gz, "GiB")
    Float read2_size = size(read_two_fastq_gz, "GiB")

    Int memory_gb_calculation = (
        ceil((read1_size + read2_size) * 0.08) + modify_memory_gb
    )
    Int memory_gb = if memory_gb_calculation > 4
        then memory_gb_calculation
        else 4

    Int disk_size_gb = ceil((read1_size + read2_size) * 2) + modify_disk_size_gb

    String args = if defined(read_two_fastq_gz) then "" else "--disable-validator P001" 

    command <<<
        fq lint ~{args} ~{read_one_fastq_gz} ~{read_two_fastq_gz}
    >>>

    output {
        File validated_read1 = read_one_fastq_gz
        File? validated_read2 = read_two_fastq_gz
    }

    runtime {
        memory: memory_gb + " GB"
        disk: disk_size_gb + " GB"
        docker: 'quay.io/biocontainers/fq:0.9.1--h9ee0642_0'
        maxRetries: max_retries
    }
}

task subsample {
    meta {
        description: "This WDL task subsamples input FastQs"
        outputs: {
            subsampled_read1: "Gzipped FastQ file containing subsampled read1"
            subsampled_read2: "Gzipped FastQ file containing subsampled read2"
        }
    }

    parameter_meta {
        read_one_fastq_gz: "Input FastQ with read one"
        read_two_fastq_gz: "Input FastQ with read two"
        prefix: "Prefix for the output FastQ file(s). The extension `_R1.subsampled.fastq.gz` and `_R2.subsampled.fastq.gz` will be added."
        probability: "The probability a record is kept, as a decimal (0.0, 1.0). Cannot be used with `record-count`. Any `probability<=0.0` or `probability>=1.0` to disable."
        record_count: "The exact number of records to keep. Cannot be used with `probability`. Any `record_count<=0` to disable."
        memory_gb: "RAM to allocate for task, specified in GB"
        modify_disk_size_gb: "Add to or subtract from dynamic disk space allocation. Default disk size is determined by the size of the inputs. Specified in GB."
        max_retries: "Number of times to retry in case of failure"
    }

    input {
        File read_one_fastq_gz
        File? read_two_fastq_gz
        String prefix = sub(
            basename(read_one_fastq_gz),
            "([_\.]R[12])?(\.subsampled)?\.(fastq|fq)(\.gz)?$",
            ""
        )
        Float probability = 1.0
        Int record_count = -1
        Int memory_gb = 4
        Int modify_disk_size_gb = 0
        Int max_retries = 1
    }

    Float read1_size = size(read_one_fastq_gz, "GiB")
    Float read2_size = size(read_two_fastq_gz, "GiB")

    Int disk_size_gb = ceil((read1_size + read2_size) * 2) + modify_disk_size_gb

    String probability_arg = if (probability < 1.0 && probability > 0)
        then "-p " + probability
        else ""
    String record_count_arg = if (record_count > 0) then "-n " + record_count else ""

    String r1_dst = prefix + "_R1.subsampled.fastq.gz"
    String r2_dst = prefix + "_R2.subsampled.fastq.gz"

    command <<<
        fq subsample \
            ~{probability_arg} \
            ~{record_count_arg} \
            --r1-dst ~{r1_dst} \
            ~{if defined(read_two_fastq_gz)
                then "--r2-dst " + r2_dst
                else ""
            } \
            ~{read_one_fastq_gz} \
            ~{read_two_fastq_gz}
    >>>

    output {
        File subsampled_read1 = prefix + "_R1.subsampled.fastq.gz"
        File? subsampled_read2 = prefix + "_R2.subsampled.fastq.gz"
    }

    runtime {
        disk: disk_size_gb + " GB"
        memory: memory_gb + " GB"
        docker: 'quay.io/biocontainers/fq:0.10.0--h9ee0642_0'
        maxRetries: max_retries
    }
}
