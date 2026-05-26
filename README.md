# Reference Genome Data Package Compile

Stages and compiles reference genome data packages for delivery to collaborators. Pulls raw reads, assemblies, and mitogenomes from Acacia object storage and the OceanOmics PostgreSQL database, then organises them into a clean per-species directory structure.

---

## Prerequisites

- `rclone` configured with your S3/Acacia remotes
- Access to the OceanOmics PostgreSQL database (`~/postgresql_details/oceanomics.cfg`)
- Singularity (`$SING` pointing to the container directory)
- The [Data_Package_Pipeline_Mitogenomes](https://github.com/OceanOmics) repo cloned locally (step 04 only)

---

## Config file

Copy and fill in `refgenomes_data_package.conf` before running any step.

```bash
# ── Scope: set ONE of PROJECT_ID or OG_ID ──────────────────────────────────
PROJECT_ID='OGP047'                        # all OGs in this project
# OG_ID='OG750,OG816'                      # specific OGs (requires PACKAGE_NAME)
# PACKAGE_NAME='minderoo_batch3'           # label used in output filenames (OG_ID mode only)

# ── Staging directory ───────────────────────────────────────────────────────
STAGING_BASE_DIR='/scratch/pawsey0964/{user}/data_packages/OGP047'

# ── Rclone remotes ──────────────────────────────────────────────────────────
ASSEMBLY_BUCKET='pawsey0964:oceanomics-refassemblies'
HIFI_BUCKET='pawsey0964:oceanomics-filtered-reads'
HIC_BUCKET='s3:oceanomics/OceanGenomes/illumina-hic'
DRAFT_BUCKET='pawsey0964:oceanomics-draftgenomes'

# ── Database ────────────────────────────────────────────────────────────────
POSTGRES_CFG='~/postgresql_details/oceanomics.cfg'

# ── Mitogenome pipeline ─────────────────────────────────────────────────────
MITO_PIPELINE_DIR='/scratch/pawsey0964/{user}/Data_Package_Pipeline_Mitogenomes'

# ── Backup (step 07) ────────────────────────────────────────────────────────
DATAPACKS_BUCKET='pawsey0964:oceanomics-datapacks'
DATAPACKS_ZIPPED_BUCKET='pawsey0964:oceanomics-datapacks-zipped'

# ── Optional ────────────────────────────────────────────────────────────────
# RCLONE_FLAGS='--dry-run --progress'      # add --dry-run to test without copying
# SING='/software/projects/pawsey0964/singularity'   # defaults to $SING env var
```

`{user}` is expanded to `$USER` at runtime.

---

## Running the pipeline

### Quickstart — run everything at once

```bash
bash run_all.sh refgenomes_data_package.conf
```

Flags:
- `--skip-db` — skip step 0 (transfer maps already exist)
- `--skip-mito` — skip step 04 (mitogenome pipeline)
- `--dry-run` — passes `--dry-run` to all rclone calls, no data is copied

Steps 01–05 run in parallel with timestamped logs written to `logs/`. Steps 06, audit, and 07 run sequentially after. The script exits early if staging or audit fails.

### Step by step

### Step 0 — Generate transfer maps and assembly stats from the database

**This must run first.** `pull_genome_statistics_by_project.py` queries PostgreSQL and writes three CSVs to `STAGING_BASE_DIR` that all downstream steps depend on:

| File | Used by | Purpose |
|---|---|---|
| `hic_transfer_map_{LABEL}_{DATE}.csv` | steps 01, 02, 03, 04 | OG ID → Hi-C tube ID mapping |
| `draft_transfer_map_{LABEL}_{DATE}.csv` | steps 03, 04, 05, 06 | Draft workflow OG IDs and species names |
| `refgenomes_assembly_stats_{LABEL}_{DATE}.csv` | step 06 | Stage-3 assembly QC stats (determines reference OG classification) |

```bash
singularity run $SING/psycopg2:0.1.sif python \
  pull_genome_statistics_by_project.py refgenomes_data_package.conf
```

### Step 01 — Stage Hi-C reads

Copies Hi-C FASTQ.gz files from `HIC_BUCKET` using the tube IDs in the Hi-C transfer map.

```bash
bash 01_get_hic_from_config.sh refgenomes_data_package.conf
```

### Step 02 — Stage HiFi reads

Copies HiFi BAM files from `HIFI_BUCKET`.

```bash
bash 02_get_hifi_from_config.sh refgenomes_data_package.conf
```

### Step 03 — Stage assemblies

Copies curated assemblies from `ASSEMBLY_BUCKET`. Tries stage-3 chromosome-level first; falls back to stage-2 (post-Tiara) if no stage-3 files exist for an OG.

```bash
bash 03_get_assembly_from_config.sh refgenomes_data_package.conf
```

### Step 04 — Run mitogenome pipeline

Runs the 7-step mitogenome pipeline for all project OGs (both reference and draft), then distributes the output into the per-OG staging directories.

```bash
bash 04_get_mito_from_config.sh refgenomes_data_package.conf
```

### Step 05 — Stage draft genomes

Copies draft genome assemblies (`.fna`) and filtered Illumina reads (R1/R2 `.fastq.gz`) from `DRAFT_BUCKET`.

```bash
bash 05_get_draft_from_config.sh refgenomes_data_package.conf
```

### Step 06 — Compile final package

Reorganises staged files into the final delivery structure, copies mitogenomes into the correct per-species directories, then removes the intermediate per-OG staging directories.

```bash
bash 06_compile_package.sh refgenomes_data_package.conf
```

### Audit

Checks the compiled package for missing files and reports PASS / WARN / FAIL per directory.

```bash
bash audit_data_package.sh refgenomes_data_package.conf
```

### Step 07 — Package and back up

Generates a recursive file listing of the compiled package, zips the directory, and uploads the zip to Acacia. Run after the audit passes.

```bash
bash 07_package_and_backup.sh refgenomes_data_package.conf
```

Four actions in sequence:
1. Copies compiled package to `DATAPACKS_BUCKET/{DATA_ID}/` (`pawsey0964:oceanomics-datapacks`)
2. Lists `DATAPACKS_BUCKET/{DATA_ID}/` and saves as `{DATA_ID}_returned_{YYMMDD}.txt` (e.g. `OGP047_returned_260526.txt`)
3. Zips the local staging directory to `{DATA_ID}_returned_{YYMMDD}.zip`
4. Uploads the zip to `DATAPACKS_ZIPPED_BUCKET` (`pawsey0964:oceanomics-datapacks-zipped`)

> **Note:** For large packages (>50 GB) submit this as a SLURM job rather than running on the login node.

---

## Output structure

Each OG is classified as one of three types based on what is available:

| Type | Criteria |
|---|---|
| `reference` | Stage-3 chromosome-level curated assembly exists in the DB |
| `draft` | Illumina `.fna` assembly present in `DRAFT_BUCKET` |
| `hifi_assembly` | HiFi assembly exists but no curated or Illumina assembly |

```
{STAGING_BASE_DIR}/
├── refgenomes_assembly_stats_{LABEL}_{DATE}.csv
├── hic_transfer_map_{LABEL}_{DATE}.csv
├── draft_transfer_map_{LABEL}_{DATE}.csv
├── mitogenome_metadata_{LABEL}.csv
├── {DATA_ID}_returned_{YYMMDD}.txt          ← file listing (step 07)
│
├── {Species}_reference/
│   ├── {OG}_v{n}.curated.hap1.chr_level.fa
│   ├── {OG}_v{n}.curated.hap2.chr_level.fa
│   ├── {OG}_v{n}.curated.hap1.assembly_summary.txt
│   ├── {OG}_v{n}.curated.hap2.assembly_summary.txt
│   └── mitogenome/
│       ├── FA/     {OG}_mitogenome.fa
│       ├── GENES/  {OG}_{gene}.fa          (absent if not annotated)
│       └── GFF/    {OG}_mitogenome.gff     (absent if not annotated)
│
├── {Species}_draft/
│   └── {OG}/
│       ├── {OG}_assembly.fna
│       ├── {OG}_R1.fastq.gz
│       ├── {OG}_R2.fastq.gz
│       └── mitogenome/
│           └── FA/  {OG}_mitogenome.fa
│
└── {Species}_hifi_assembly/
    ├── assembly/
    │   ├── {OG}.asm.bp.hap1.p_ctg.fasta
    │   └── {OG}.asm.bp.hap1.p_ctg.gfa
    ├── gfastats/
    │   └── {OG}_assembly_summary.txt
    ├── hifi_reads_raw/
    │   └── {OG}_m{run}.bam
    └── mitogenome/
        └── FA/  {OG}_mitogenome.fa
```

---

## Data types

| File | Format | Description |
|---|---|---|
| `*curated.hap1/hap2.chr_level.fa` | FASTA | Chromosome-level curated diploid assembly (hap1 and hap2) |
| `*assembly_summary.txt` | TSV | Per-sequence statistics from gfastats (N50, L50, size, etc.) |
| `*.bam` | BAM | Raw PacBio HiFi long reads (CCS) |
| `*.fastq.gz` (Hi-C) | FASTQ | Paired-end Hi-C chromatin proximity reads (Illumina) |
| `*.fastq.gz` / `*.fq.gz` (draft reads) | FASTQ | Illumina short reads, adapter-trimmed via fastp |
| `*.fna` | FASTA | Draft genome assembly (Illumina short-read assembly) |
| `*.fasta` / `*.gfa` | FASTA / GFA | Hifiasm primary assembly contigs and assembly graph |
| `mitogenome/FA/*.fa` | FASTA | Mitochondrial genome sequence |
| `mitogenome/GENES/*.fa` | FASTA | Individual mitochondrial gene sequences (CDS) |
| `mitogenome/GFF/*.gff` | GFF3 | Mitochondrial genome annotation |
| `refgenomes_assembly_stats_*.csv` | CSV | Assembly QC metrics: N50, BUSCO, Merqury QV, chromosome assignment |
| `mitogenome_metadata_*.csv` | CSV | Mitogenome accession and metadata for all project OGs |

---

## Notes

- Run all scripts from the `get_data_package/` directory with the config file as the only argument.
- `RCLONE_FLAGS='--dry-run'` is useful for verifying what will be copied before running for real.
- Steps 01–05 are independent and can be re-run without affecting each other. Step 06 is destructive (removes intermediate staging dirs) — only run it once steps 01–05 are complete and the audit passes.
- Projects with no draft workflow OGs (reference-only) will skip steps 03 and 05 draft sections without error.
