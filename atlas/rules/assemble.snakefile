import os
import re
import sys
from glob import glob
from snakemake.utils import report
import warnings


localrules: rename_megahit_output, rename_spades_output, initialize_checkm, \
            finalize_contigs, build_bin_report, build_assembly_report


def get_preprocessing_steps(config):
    preprocessing_steps = ["normalized"]
    if config.get("merge_pairs_before_assembly", True) and PAIRED_END:
        preprocessing_steps.append("merged")
    if config.get("error_correction_overlapping_pairs", True):
        preprocessing_steps.append("errorcorr")
    return ".".join(preprocessing_steps)


def gff_to_gtf(gff_in, gtf_out):
    # orf_re = re.compile(r"ID=(.*?)\;")
    with open(gtf_out, "w") as fh, open(gff_in) as gff:
        for line in gff:
            if line.startswith("##FASTA"): break
            if line.startswith("#"): continue
            # convert:
            # ID=POMFPAEF_00802;inference=ab initio prediction:Prodigal:2.60;
            # to
            # ID POMFPAEF_00802; inference ab initio prediction:Prodigal:2.60;
            toks = line.strip().split("\t")
            toks[-1] = toks[-1].replace("=", " ").replace(";", "; ")
            print(*toks, sep="\t", file=fh)


def bb_cov_stats_to_maxbin(tsv_in, tsv_out):
    with open(tsv_in) as fi, open(tsv_out, "w") as fo:
        # header
        next(fi)
        for line in fi:
            toks = line.strip().split("\t")
            print(toks[0], toks[1], sep="\t", file=fo)


assembly_preprocessing_steps = get_preprocessing_steps(config)


rule normalize_coverage_across_kmers:
    input:
        unpack(get_quality_controlled_reads) #expect SE or R1,R2 or R1,R2,SE
    output:
        temp(expand("{{sample}}/assembly/reads/normalized_{fraction}.fastq.gz",
            fraction=MULTIFILE_FRACTIONS))
    benchmark:
        "logs/benchmarks/normalization/{sample}.txt"
    params:
        k = config.get("normalization_kmer_length", NORMALIZATION_KMER_LENGTH),
        t = config.get("normalization_target_depth", NORMALIZATION_TARGET_DEPTH),
        minkmers = config.get("normalization_minimum_kmers", NORMALIZATION_MINIMUM_KMERS),
        input_single = lambda wc, input: "in=%s" % input.se if hasattr(input, 'se') else "null",
        extra_single = lambda wc, input: "extra=%s,%s" % (input.R1, input.R2) if hasattr(input, 'R1') else "",
        has_paired_end_files = lambda wc, input: "t" if hasattr(input, 'R1') else "f",
        input_paired = lambda wc, input: "in=%s in2=%s" % (input.R1, input.R2) if hasattr(input, 'R1') else "null",
        extra_paired = lambda wc, input: "extra=%s" % input.se if hasattr(input, 'se') else "",
        output_single = lambda wc, output, input: "out=%s" % output[2] if hasattr(input, 'R1') else "out=%s" % output[0],
        output_paired = lambda wc, output, input: "out=%s out2=%s" % (output[0], output[1]) if hasattr(input, 'R1') else "null",
        tmpdir = "tmpdir=%s" % TMPDIR if TMPDIR else ""
    log:
        "{sample}/logs/{sample}_normalization.log"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    resources:
        mem = config.get("java_mem", JAVA_MEM),
        java_mem = int(config.get("java_mem", JAVA_MEM) * JAVA_MEM_FRACTION)
    shell:
        """
        if [ {params.input_single} != "null" ];
        then
            bbnorm.sh {params.input_single} \
                {params.extra_single} \
                {params.output_single} \
                {params.tmpdir} \
                k={params.k} target={params.t} \
                minkmers={params.minkmers} prefilter=t \
                threads={threads} \
                -Xmx{resources.java_mem}G 2> {log}
        fi

        if [ {params.has_paired_end_files} = "t" ];
        then
            bbnorm.sh {params.input_paired} \
                {params.extra_paired} \
                {params.output_paired} \
                {params.tmpdir} \
                k={params.k} target={params.t} \
                minkmers={params.minkmers} prefilter=t \
                threads={threads} \
                -Xmx{resources.java_mem}G 2>> {log}
        fi
        """


rule error_correction:
    input:
        expand("{{sample}}/assembly/reads/{{previous_steps}}_{fraction}.fastq.gz",
            fraction=MULTIFILE_FRACTIONS)
    output:
        temp(expand("{{sample}}/assembly/reads/{{previous_steps}}.errorcorr_{fraction}.fastq.gz",
            fraction=MULTIFILE_FRACTIONS))
    benchmark:
        "logs/benchmarks/error_correction/{sample}.txt"
    log:
        "{sample}/logs/{sample}_error_correction.log"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    resources:
        mem = config.get("java_mem", JAVA_MEM),
        java_mem = int(config.get("java_mem", JAVA_MEM) * JAVA_MEM_FRACTION)
    params:
        inputs = lambda wc, input: "in1={0},{2} in2={1}".format(*input) if PAIRED_END else "in={0}".format(*input),
        outputs = lambda wc, output: "out1={0},{2} out2={1}".format(*output) if PAIRED_END else "out={0}".format(*output)
    threads:
        config.get("threads", 1)
    shell:
        """
        tadpole.sh -Xmx{resources.java_mem}G \
            prealloc=1 \
            {params.inputs} \
            {params.outputs} \
            mode=correct \
            threads={threads} \
            ecc=t ecco=t 2>> {log}
        """


rule merge_pairs:
    input:
        expand("{{sample}}/assembly/reads/{{previous_steps}}_{fraction}.fastq.gz",
            fraction=MULTIFILE_FRACTIONS)
    output:
        temp(expand("{{sample}}/assembly/reads/{{previous_steps}}.merged_{fraction}.fastq.gz",
            fraction=MULTIFILE_FRACTIONS))
    threads:
        config.get("threads", 1)
    resources:
        mem = config.get("java_mem", JAVA_MEM),
        java_mem = int(config.get("java_mem", JAVA_MEM) * JAVA_MEM_FRACTION)
    conda:
        "%s/required_packages.yaml" % CONDAENV
    log:
        "{sample}/logs/{sample}_merge_pairs.log"
    benchmark:
        "logs/benchmarks/merge_pairs/{sample}.txt"
    shadow:
        "shallow"
    params:
        kmer = config.get("merging_k", MERGING_K),
        extend2 = config.get("merging_extend2", MERGING_EXTEND2),
        flags = config.get("merging_flags", MERGING_FLAGS),
        outmerged = lambda wc, output: os.path.join(os.path.dirname(output[0]), "%s_merged_pairs.fastq.gz" % wc.sample)
    shell:
        """
        bbmerge.sh -Xmx{resources.java_mem}G threads={threads} \
            in1={input[0]} in2={input[1]} \
            outmerged={params.outmerged} \
            outu={output[0]} outu2={output[1]} \
            {params.flags} k={params.kmer} \
            extend2={params.extend2} 2> {log}

        cat {params.outmerged} {input[2]} \
            > {output[2]} 2>> {log}
        """

assembly_params={}
if config.get("assembler", "megahit") == "megahit":
    assembly_params['megahit']={'default':'','meta-sensitive':'--presets meta-sensitive','meta-large':' --presets meta-large'}

    rule run_megahit:
        input:
            expand("{{sample}}/assembly/reads/{assembly_preprocessing_steps}_{fraction}.fastq.gz",
            fraction=MULTIFILE_FRACTIONS, assembly_preprocessing_steps=assembly_preprocessing_steps)
        output:
            temp("{sample}/assembly/{sample}_prefilter.contigs.fa")
        benchmark:
            "logs/benchmarks/assembly/{sample}.txt"
        # shadow:
        #     "full"
        log:
            "{sample}/logs/{sample}_megahit.log"
        params:
            min_count = config.get("megahit_min_count", MEGAHIT_MIN_COUNT),
            k_min = config.get("megahit_k_min", MEGAHIT_K_MIN),
            k_max = config.get("megahit_k_max", MEGAHIT_K_MAX),
            k_step = config.get("megahit_k_step", MEGAHIT_K_STEP),
            merge_level = config.get("megahit_merge_level", MEGAHIT_MERGE_LEVEL),
            prune_level = config.get("megahit_prune_level", MEGAHIT_PRUNE_LEVEL),
            low_local_ratio = config.get("megahit_low_local_ratio", MEGAHIT_LOW_LOCAL_RATIO),
            min_contig_len = config.get("prefilter_minimum_contig_length", PREFILTER_MINIMUM_CONTIG_LENGTH),
            outdir = lambda wc, output: os.path.dirname(output[0]),
            inputs = lambda wc, input: "-1 {0} -2 {1} --read {2}".format(*input) if PAIRED_END else "--read {0}".format(*input),
            preset = assembly_params['megahit'][config['megahit_preset']]

        conda:
            "%s/required_packages.yaml" % CONDAENV
        threads:
            config.get("assembly_threads", ASSEMBLY_THREADS)
        resources:
            mem = config.get("assembly_memory", ASSEMBLY_MEMORY) #in GB
        shell:
            """
            megahit --continue \
                {params.inputs} \
                --tmp-dir {TMPDIR} \
                --num-cpu-threads {threads} \
                --k-min {params.k_min} \
                --k-max {params.k_max} \
                --k-step {params.k_step} \
                --out-dir {params.outdir} \
                --out-prefix {wildcards.sample}_prefilter \
                --min-contig-len {params.min_contig_len} \
                --min-count {params.min_count} \
                --merge-level {params.merge_level} \
                --prune-level {params.prune_level} \
                --low-local-ratio {params.low_local_ratio} \
                --memory {resources.mem}000000000  \
                {params.preset} > {log} 2>&1
            """


    rule rename_megahit_output:
        input:
            "{sample}/assembly/{sample}_prefilter.contigs.fa"
        output:
            temp("{sample}/assembly/{sample}_raw_contigs.fasta")
        shell:
            "cp {input} {output}"


else:
    assembly_params['spades'] = {'meta':'--meta','normal':''}

    rule run_spades:
        input:
            expand("{{sample}}/assembly/reads/{assembly_preprocessing_steps}_{fraction}.fastq.gz",
                fraction=MULTIFILE_FRACTIONS,
                assembly_preprocessing_steps=assembly_preprocessing_steps)
        output:
            temp("{sample}/assembly/contigs.fasta")
        benchmark:
            "logs/benchmarks/assembly/{sample}.txt"
        params:
            inputs = lambda wc, input: "-1 {0} -2 {1} -s {2}".format(*input) if PAIRED_END else "-s {0}".format(*input),
            k = config.get("spades_k", SPADES_K),
            outdir = lambda wc: "{sample}/assembly".format(sample=wc.sample),
            preset = assembly_params['spades'][config['spades_preset']]
            # min_length=config.get("prefilter_minimum_contig_length", PREFILTER_MINIMUM_CONTIG_LENGTH)
        log:
            "{sample}/logs/{sample}_spades.log"
        # shadow:
        #     "full"
        conda:
            "%s/required_packages.yaml" % CONDAENV
        threads:
            config.get("assembly_threads", ASSEMBLY_THREADS)
        resources:
            mem=config.get("assembly_memory", ASSEMBLY_MEMORY) #in GB
        shell:
            """
            spades.py --threads {threads} --memory {resources.mem} \
                -o {params.outdir} {params.preset} {params.inputs} > {log} 2>&1
            """


    rule rename_spades_output:
        input:
            "{sample}/assembly/contigs.fasta"
        output:
            temp("{sample}/assembly/{sample}_raw_contigs.fasta")
        shell:
            "cp {input} {output}"


rule rename_contigs:
    # standardizes header labels within contig FASTAs
    input:
        "{sample}/assembly/{sample}_raw_contigs.fasta"
    output:
        "{sample}/assembly/{sample}_prefilter_contigs.fasta"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    shell:
        """rename.sh in={input} out={output} ow=t prefix={wildcards.sample}"""


rule calculate_contigs_stats:
    input:
        "{sample}/assembly/{sample}_{assembly_step}_contigs.fasta"
    output:
        "{sample}/assembly/contig_stats/{assembly_step}_contig_stats.txt"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        1
    resources:
        mem = 1
    shell:
        "stats.sh in={input} format=3 > {output}"


rule combine_sample_contig_stats:
    input:
        expand("{{sample}}/assembly/contig_stats/{assembly_step}_contig_stats.txt", assembly_step= ['prefilter','final'])
    output:
        "{sample}/assembly/contig_stats.tsv"
    run:
        import os
        import pandas as pd

        c = pd.DataFrame()
        for f in input:
            df = pd.read_table(f)
            assembly_step = os.path.basename(f).replace("_contig_stats.txt", "")
            c.loc[assembly_step]

        c.to_csv(output[0], sep='\t')


rule calculate_prefiltered_contig_coverage_stats:
    input:
        unpack(get_quality_controlled_reads),
        fasta = "{sample}/assembly/{sample}_prefilter_contigs.fasta"
    output: # bbwrap gives output statistics only for single ended
        covstats = "{sample}/assembly/contig_stats/prefilter_coverage_stats.txt",
        sam = temp("{sample}/sequence_alignment/alignment_to_prefilter_contigs.sam")
    benchmark:
        "logs/benchmarks/calculate_prefiltered_contig_coverage_stats/{sample}.txt"
    params:
        input = lambda wc, input : input_params_for_bbwrap(wc, input),
        maxsites = config.get("maximum_counted_map_sites", MAXIMUM_COUNTED_MAP_SITES),
        max_distance_between_pairs = config.get('contig_max_distance_between_pairs', CONTIG_MAX_DISTANCE_BETWEEN_PAIRS),
        paired_only = 't' if config.get("contig_map_paired_only", CONTIG_MAP_PAIRED_ONLY) else 'f',
        min_id = config.get('contig_min_id', CONTIG_MIN_ID),
        maxindel = 100,
        #ambiguous = 'all' if CONTIG_COUNT_MULTI_MAPPED_READS else 'best'
    log:
        "{sample}/assembly/logs/prefiltered_contig_coverage_stats.log"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    resources:
        mem = config.get("java_mem", JAVA_MEM),
        java_mem = int(config.get("java_mem", JAVA_MEM) * JAVA_MEM_FRACTION)
    shell:
        """bbwrap.sh \
               nodisk=t \
               ref={input.fasta} \
               {params.input} \
               fast=t \
               threads={threads} \
               ambiguous=all \
              pairlen={params.max_distance_between_pairs} \
              pairedonly={params.paired_only} \
              mdtag=t \
              xstag=fs \
              nmtag=t \
              local=t \
              secondary=t \
              maxsites={params.maxsites} \
               -Xmx{resources.java_mem}G \
               out={output.sam} 2> {log}

            pileup.sh \
            ref={input.fasta} \
            in={output.sam} \
            threads={threads} \
            secondary=t \
            -Xmx{resources.java_mem}G \
            covstats={output.covstats} 2>> {log}
        """


rule filter_by_coverage:
    input:
        fasta = "{sample}/assembly/{sample}_prefilter_contigs.fasta",
        covstats = "{sample}/assembly/contig_stats/prefilter_coverage_stats.txt"
    output:
        fasta = temp("{sample}/assembly/{sample}_final_contigs.fasta"),
        removed_names = "{sample}/assembly/{sample}_discarded_contigs.fasta"
    params:
        minc = config.get("minimum_average_coverage", MINIMUM_AVERAGE_COVERAGE),
        minp = config.get("minimum_percent_covered_bases", MINIMUM_PERCENT_COVERED_BASES),
        minr = config.get("minimum_mapped_reads", MINIMUM_MAPPED_READS),
        minl = config.get("minimum_contig_length", MINIMUM_CONTIG_LENGTH),
        trim = config.get("contig_trim_bp", CONTIG_TRIM_BP)
    log:
        "{sample}/assembly/logs/filter_by_coverage.log"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        1
    resources:
        mem = config.get("java_mem", JAVA_MEM),
        java_mem = int(config.get("java_mem", JAVA_MEM) * JAVA_MEM_FRACTION)
    shell:
        """filterbycoverage.sh in={input.fasta} \
               cov={input.covstats} \
               out={output.fasta} \
               outd={output.removed_names} \
               minc={params.minc} \
               minp={params.minp} \
               minr={params.minr} \
               minl={params.minl} \
               trim={params.trim} \
               -Xmx{resources.java_mem}G 2> {log}"""


rule finalize_contigs:
    input:
        "{sample}/assembly/{sample}_final_contigs.fasta"
    output:
        "{sample}/{sample}_contigs.fasta"
    threads:
        1
    shell:
        "cp {input} {output}"


rule align_reads_to_final_contigs:
    input:
        unpack(get_quality_controlled_reads),
        fasta = "{sample}/{sample}_contigs.fasta",
    output:
        sam = temp("{sample}/sequence_alignment/{sample}.sam"),
        unmapped = expand("{{sample}}/assembly/unmapped_post_filter/{{sample}}_unmapped_{fraction}.fastq.gz",
                          fraction=MULTIFILE_FRACTIONS)
    params:
        input = lambda wc, input : input_params_for_bbwrap(wc, input),
        maxsites = config.get("maximum_counted_map_sites", MAXIMUM_COUNTED_MAP_SITES),
        unmapped = lambda wc, output: "outu1={0},{2} outu2={1},null".format(*output.unmapped) if PAIRED_END else "outu={0}".format(*output.unmapped),
        max_distance_between_pairs = config.get('contig_max_distance_between_pairs', CONTIG_MAX_DISTANCE_BETWEEN_PAIRS),
        paired_only = 't' if config.get("contig_map_paired_only", CONTIG_MAP_PAIRED_ONLY) else 'f',
        ambiguous = 'all' if CONTIG_COUNT_MULTI_MAPPED_READS else 'best',
        min_id = config.get('contig_min_id', CONTIG_MIN_ID),
        maxindel = 100 # default 16000 good for genome deletions but not necessarily for alignment to contigs
    benchmark:
        "logs/benchmarks/align_reads_to_filtered_contigs/{sample}.txt"
    log:
        "{sample}/assembly/logs/contig_coverage_stats.log"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    resources:
        mem = config.get("java_mem", JAVA_MEM),
        java_mem = int(config.get("java_mem", JAVA_MEM) * JAVA_MEM_FRACTION)
    shell:
        """bbwrap.sh nodisk=t \
               ref={input.fasta} \
               {params.input} \
               trimreaddescriptions=t \
               outm={output.sam} \
               {params.unmapped} \
               threads={threads} \
               pairlen={params.max_distance_between_pairs} \
               pairedonly={params.paired_only} \
               minid={params.min_id} \
               mdtag=t \
               xstag=fs \
               nmtag=t \
               sam=1.3 \
               local=t \
               ambiguous={params.ambiguous} \
               secondary=t \
               ssao=t \
               maxsites={params.maxsites} \
               -Xmx{resources.java_mem}G \
               2> {log}
        """


rule pileup:
    input:
        fasta = "{sample}/{sample}_contigs.fasta",
        sam = "{sample}/sequence_alignment/{sample}.sam",
    output:
        basecov = temp("{sample}/assembly/contig_stats/postfilter_base_coverage.txt.gz"),
        covhist = "{sample}/assembly/contig_stats/postfilter_coverage_histogram.txt",
        covstats = "{sample}/assembly/contig_stats/postfilter_coverage_stats.txt",
        bincov = "{sample}/assembly/contig_stats/postfilter_coverage_binned.txt"
    params:
        pileup_secondary = 't' if config.get("count_multi_mapped_reads", CONTIG_COUNT_MULTI_MAPPED_READS) else 'f',
        physcov = 't' if not config.get("count_multi_mapped_reads", CONTIG_COUNT_MULTI_MAPPED_READS) else 'f'
    benchmark:
        "logs/benchmarks/align_reads_to_filtered_contigs/{sample}_pileup.txt"
    log:
        "{sample}/logs/assembly/pilup_final_contigs.log" # this file is udes for assembly report
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    resources:
        mem = config.get("java_mem", JAVA_MEM),
        java_mem = int(config.get("java_mem", JAVA_MEM) * JAVA_MEM_FRACTION)
    shell:
        """pileup.sh ref={input.fasta} in={input.sam} \
               threads={threads} \
               -Xmx{resources.java_mem}G \
               covstats={output.covstats} \
               hist={output.covhist} \
               basecov={output.basecov}\
               concise=t \
               physcov={params.physcov} \
               secondary={params.pileup_secondary} \
               bincov={output.bincov} 2> {log}"""


if config.get("perform_genome_binning", True):
    rule make_maxbin_abundance_file:
        input:
            "{sample}/assembly/contig_stats/postfilter_coverage_stats.txt"
        output:
            "{sample}/genomic_bins/{sample}_contig_coverage.tsv"
        run:
            bb_cov_stats_to_maxbin(input[0], output[0])


    rule run_maxbin:
        input:
            fasta = "{sample}/{sample}_contigs.fasta",
            abundance = "{sample}/genomic_bins/{sample}_contig_coverage.tsv"
        output:
            # fastas will need to be dynamic if we do something with them at a later time
            summary = "{sample}/genomic_bins/{sample}.summary",
            marker = "{sample}/genomic_bins/{sample}.marker"
        benchmark:
            "logs/benchmarks/maxbin2/{sample}.txt"
        params:
            mi = config.get("maxbin_max_iteration", MAXBIN_MAX_ITERATION),
            mcl = config.get("maxbin_min_contig_length", MAXBIN_MIN_CONTIG_LENGTH),
            pt = config.get("maxbin_prob_threshold", MAXBIN_PROB_THRESHOLD),
            outdir = lambda wildcards, output: os.path.join(os.path.dirname(output.summary), wildcards.sample)
        log:
            "{sample}/logs/maxbin2.log"
        conda:
            "%s/optional_genome_binning.yaml" % CONDAENV
        threads:
            config.get("threads", 1)
        shell:
            """run_MaxBin.pl -contig {input.fasta} \
                   -abund {input.abundance} \
                   -out {params.outdir} \
                   -min_contig_length {params.mcl} \
                   -thread {threads} \
                   -prob_threshold {params.pt} \
                   -max_iteration {params.mi} > {log}"""


    rule initialize_checkm:
        # input:
        output:
            touched_output = "logs/checkm_init.txt"
        params:
            database_dir = CHECKMDIR
        conda:
            "%s/optional_genome_binning.yaml" % CONDAENV
        log:
            "logs/initialize_checkm.log"
        shell:
            "python %s/rules/initialize_checkm.py {params.database_dir} {output.touched_output} {log}" % os.path.dirname(os.path.abspath(workflow.snakefile))


    rule run_checkm_lineage_wf:
        input:
            touched_output = "logs/checkm_init.txt",
            # init_checkm = "%s/hmms/checkm.hmm" % CHECKMDIR,
            bins = "{sample}/genomic_bins/{sample}.marker"
        output:
            "{sample}/genomic_bins/checkm/completeness.tsv"
        params:
            bin_dir = lambda wc, input: os.path.dirname(input.bins),
            output_dir = lambda wc, output: os.path.dirname(output[0])
        conda:
            "%s/optional_genome_binning.yaml" % CONDAENV
        threads:
            config.get("threads", 1)
        shell:
            """rm -r {params.output_dir} && \
               checkm lineage_wf \
                   --file {params.output_dir}/completeness.tsv \
                   --tab_table \
                   --quiet \
                   --extension fasta \
                   --threads {threads} \
                   {params.bin_dir} \
                   {params.output_dir}"""


    rule run_checkm_tree_qa:
        input:
            "{sample}/genomic_bins/checkm/completeness.tsv"
        output:
            "{sample}/genomic_bins/checkm/taxonomy.tsv"
        params:
            output_dir = "{sample}/genomic_bins/checkm"
        conda:
            "%s/optional_genome_binning.yaml" % CONDAENV
        shell:
            """checkm tree_qa \
                   --tab_table \
                   --out_format 2 \
                   --file {params.output_dir}/taxonomy.tsv \
                   {params.output_dir}"""


rule build_bin_report:
    input:
        completeness_files = expand("{sample}/genomic_bins/checkm/completeness.tsv", sample=SAMPLES),
        taxonomy_files = expand("{sample}/genomic_bins/checkm/taxonomy.tsv", sample=SAMPLES)
    output:
        report = "reports/bin_report.html",
        bin_table = "genomic_bins.tsv"
    params:
        samples = " ".join(SAMPLES)
    conda:
        "%s/report.yaml" % CONDAENV
    shell:
        """
        python %s/report/bin_report.py \
            --samples {params.samples} \
            --completeness {input.completeness_files} \
            --taxonomy {input.taxonomy_files} \
            --report-out {output.report} \
            --bin-table {output.bin_table}
        """ % os.path.dirname(os.path.abspath(workflow.snakefile))


rule convert_sam_to_bam:
    input:
        "{file}.sam"
    output:
        "{file}.bam"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    resources:
        mem = 2 * config.get("threads", 1)
    shell:
        """samtools view \
               -m 1G \
               -@ {threads} \
               -bSh1 {input} | samtools sort \
                                   -m 1G \
                                   -@ {threads} \
                                   -T {wildcards.file}_tmp \
                                   -o {output} \
                                   -O bam -
        """


rule create_bam_index:
    input:
        "{file}.bam"
    output:
        "{file}.bam.bai"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        1
    shell:
        "samtools index {input}"


rule run_prokka_annotation:
    input:
        "{sample}/{sample}_contigs.fasta"
    output:
        discrepancy = "{sample}/annotation/prokka/{sample}.err",
        faa = "{sample}/annotation/prokka/{sample}.faa",
        ffn = "{sample}/annotation/prokka/{sample}.ffn",
        fna = "{sample}/annotation/prokka/{sample}.fna",
        fsa = "{sample}/annotation/prokka/{sample}.fsa",
        gff = "{sample}/annotation/prokka/{sample}.gff",
        log = "{sample}/annotation/prokka/{sample}.log",
        tbl = "{sample}/annotation/prokka/{sample}.tbl",
        tsv = "{sample}/annotation/prokka/{sample}.tsv",
        txt = "{sample}/annotation/prokka/{sample}.txt"
    benchmark:
        "logs/benchmarks/prokka/{sample}.txt"
    params:
        outdir = lambda wc, output: os.path.dirname(output.faa),
        kingdom = config.get("prokka_kingdom", PROKKA_KINGDOM)
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    shell:
        """prokka --outdir {params.outdir} \
               --force \
               --prefix {wildcards.sample} \
               --locustag {wildcards.sample} \
               --kingdom {params.kingdom} \
               --metagenome \
               --cpus {threads} \
               {input}"""


rule update_prokka_tsv:
    input:
        "{sample}/annotation/prokka/{sample}.gff"
    output:
        "{sample}/annotation/prokka/{sample}_plus.tsv"
    shell:
        """atlas gff2tsv {input} {output}"""


rule convert_gff_to_gtf:
    input:
        "{sample}/annotation/prokka/{sample}.gff"
    output:
        "{sample}/annotation/prokka/{sample}.gtf"
    run:
        gff_to_gtf(input[0], output[0])


rule find_counts_per_region:
    input:
        gtf = "{sample}/annotation/prokka/{sample}.gtf",
        bam = "{sample}/sequence_alignment/{sample}.bam"
    output:
        summary = "{sample}/annotation/feature_counts/{sample}_counts.txt.summary",
        counts = "{sample}/annotation/feature_counts/{sample}_counts.txt"
    params:
        min_read_overlap = config.get("minimum_region_overlap", MINIMUM_REGION_OVERLAP),
        paired_only= "-B" if config.get('contig_map_paired_only',CONTIG_MAP_PAIRED_ONLY) else "",
        paired_mode = "-p" if PAIRED_END else "",
        multi_mapping = "-M --fraction" if config.get("contig_count_multi_mapped_reads",CONTIG_COUNT_MULTI_MAPPED_READS) else "--primary",
        feature_counts_allow_overlap = "-O --fraction" if config.get("feature_counts_allow_overlap", FEATURE_COUNTS_ALLOW_OVERLAP) else ""
    log:
        "{sample}/logs/counts_per_region.log"
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    shell:
        """featureCounts \
                --minOverlap {params.min_read_overlap} \
                {params.paired_mode} \
                {params.paired_only} \
               -F GTF \
               -T {threads} \
               {params.multi_mapping} \
               {params.feature_counts_allow_overlap} \
               -t CDS \
               -g ID \
               -a {input.gtf} \
               -o {output.counts} \
               {input.bam} 2> {log}"""


rule run_diamond_blastp:
    input:
        fasta = "{sample}/annotation/prokka/{sample}.faa",
        db = config["diamond_db"]
    output:
        "{sample}/annotation/refseq/{sample}_hits.tsv"
    benchmark:
        "logs/benchmarks/run_diamond_blastp/{sample}.txt"
    params:
        tmpdir = "--tmpdir %s" % TMPDIR if TMPDIR else "",
        top_seqs = config.get("diamond_top_seqs", DIAMOND_TOP_SEQS),
        e_value = config.get("diamond_e_value", DIAMOND_E_VALUE),
        min_identity = config.get("diamond_min_identity", DIAMOND_MIN_IDENTITY),
        query_cover = config.get("diamond_query_coverage", DIAMOND_QUERY_COVERAGE),
        gap_open = config.get("diamond_gap_open", DIAMOND_GAP_OPEN),
        gap_extend = config.get("diamond_gap_extend", DIAMOND_GAP_EXTEND),
        block_size = config.get("diamond_block_size", DIAMOND_BLOCK_SIZE),
        index_chunks = config.get("diamond_index_chunks", DIAMOND_INDEX_CHUNKS),
        run_mode = "--more-sensitive" if not config.get("diamond_run_mode", "") == "fast" else ""
    conda:
        "%s/required_packages.yaml" % CONDAENV
    threads:
        config.get("threads", 1)
    shell:
        """diamond blastp \
               --threads {threads} \
               --outfmt 6 \
               --out {output} \
               --query {input.fasta} \
               --db {input.db} \
               --top {params.top_seqs} \
               --evalue {params.e_value} \
               --id {params.min_identity} \
               --query-cover {params.query_cover} \
               {params.run_mode} \
               --gapopen {params.gap_open} \
               --gapextend {params.gap_extend} \
               {params.tmpdir} \
               --block-size {params.block_size} \
               --index-chunks {params.index_chunks}"""


rule add_contig_metadata:
    input:
        hits = "{sample}/annotation/refseq/{sample}_hits.tsv",
        gff = "{sample}/annotation/prokka/{sample}.gff"
    output:
        temp("{sample}/annotation/refseq/{sample}_hits_plus.tsv")
    shell:
        "atlas munge-blast {input.hits} {input.gff} {output}"


rule sort_munged_blast_hits:
    # ensure blast hits are grouped by contig, ORF, and then decreasing by bitscore
    input:
        "{sample}/annotation/refseq/{sample}_hits_plus.tsv"
    output:
        "{sample}/annotation/refseq/{sample}_hits_plus_sorted.tsv"
    shell:
        "sort -k1,1 -k2,2 -k13,13rn {input} > {output}"


rule parse_blastp:
    # assign a taxonomy to contigs using the consensus of the ORF assignments
    input:
        "{sample}/annotation/refseq/{sample}_hits_plus_sorted.tsv"
    output:
        "{sample}/annotation/refseq/{sample}_tax_assignments.tsv"
    params:
        namemap = config["refseq_namemap"],
        treefile = config["refseq_tree"],
        summary_method = config.get("summary_method", SUMMARY_METHOD),
        aggregation_method = config.get("aggregation_method", AGGREGATION_METHOD),
        majority_threshold = config.get("majority_threshold", MAJORITY_THRESHOLD),
        min_identity = config.get("diamond_min_identity", DIAMOND_MIN_IDENTITY),
        min_bitscore = config.get("min_bitscore", MIN_BITSCORE),
        min_length = config.get("min_length", MIN_LENGTH),
        max_evalue = config.get("diamond_e_value", DIAMOND_E_VALUE),
        max_hits = config.get("max_hits", MAX_HITS),
        top_fraction = (100 - config.get("diamond_top_seqs", 5)) * 0.01
    shell:
        """atlas refseq \
               --summary-method {params.summary_method} \
               --aggregation-method {params.aggregation_method} \
               --majority-threshold {params.majority_threshold} \
               --min-identity {params.min_identity} \
               --min-bitscore {params.min_bitscore} \
               --min-length {params.min_length} \
               --max-evalue {params.max_evalue} \
               --max-hits {params.max_hits} \
               --top-fraction {params.top_fraction} \
               {input} \
               {params.namemap} \
               {params.treefile} \
               {output}"""


if config.get("perform_genome_binning", True):
    rule merge_sample_tables:
        input:
            prokka = "{sample}/annotation/prokka/{sample}_plus.tsv",
            refseq = "{sample}/annotation/refseq/{sample}_tax_assignments.tsv",
            counts = "{sample}/annotation/feature_counts/{sample}_counts.txt",
            completeness = "{sample}/genomic_bins/checkm/completeness.tsv",
            taxonomy = "{sample}/genomic_bins/checkm/taxonomy.tsv"
        output:
            "{sample}/{sample}_annotations.txt"
        params:
            fastas = lambda wc: " --fasta ".join(glob("{sample}/genomic_bins/{sample}.*.fasta".format(sample=wc.sample)))
        shell:
            "atlas merge-tables \
                 --counts {input.counts} \
                 --completeness {input.completeness} \
                 --taxonomy {input.taxonomy} \
                 --fasta {params.fastas} \
                 {input.prokka} \
                 {input.refseq} \
                 {output}"


else:
    rule merge_sample_tables:
        input:
            prokka = "{sample}/annotation/prokka/{sample}_plus.tsv",
            refseq = "{sample}/annotation/refseq/{sample}_tax_assignments.tsv",
            counts = "{sample}/annotation/feature_counts/{sample}_counts.txt",
        output:
            "{sample}/{sample}_annotations.txt"
        shell:
            "atlas merge-tables \
                 --counts {input.counts} \
                 {input.prokka} \
                 {input.refseq} \
                 {output}"


rule build_assembly_report:
    input:
        contig_stats = expand("{sample}/assembly/contig_stats/final_contig_stats.txt", sample=SAMPLES),
        gene_tables = expand("{sample}/annotation/prokka/{sample}_plus.tsv", sample=SAMPLES),
        mapping_log_files = expand("{sample}/logs/assembly/pilup_final_contigs.log", sample=SAMPLES),
        # mapping logs will be incomplete unless we wait on alignment to finish
        bams = expand("{sample}/sequence_alignment/{sample}.bam", sample=SAMPLES)
    output:
        report = "reports/assembly_report.html",
        combined_contig_stats = 'stats/combined_contig_stats.tsv'
    params:
        samples = " ".join(SAMPLES)
    conda:
        "%s/report.yaml" % CONDAENV
    shell:
        """
        python %s/report/assembly_report.py \
            --samples {params.samples} \
            --contig-stats {input.contig_stats} \
            --gene-tables {input.gene_tables} \
            --mapping-logs {input.mapping_log_files} \
            --report-out {output.report} \
            --combined-stats {output.combined_contig_stats}
        """ % os.path.dirname(os.path.abspath(workflow.snakefile))
