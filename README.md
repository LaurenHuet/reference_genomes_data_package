# get_data_package

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
ASSEMBLY_BUCKET='pawsey0964:oceanomics-assemblies'
HIFI_BUCKET='pawsey0964:oceanomics-hifi'
HIC_BUCKET='pawsey0964:oceanomics-hic'
DRAFT_BUCKET='pawsey0964:oceanomics-draft-genomes'

# ── Database ────────────────────────────────────────────────────────────────
POSTGRES_CFG='~/postgresql_details/oceanomics.cfg'

# ── Mitogenome pipeline ─────────────────────────────────────────────────────
MITO_PIPELINE_DIR='/scratch/pawsey0964/{user}/Data_Package_Pipeline_Mitogenomes'

# ── Optional ────────────────────────────────────────────────────────────────
# RCLONE_FLAGS='--dry-run --progress'      # add --dry-run to test without copying
# SING='/software/projects/pawsey0964/singularity'   # defaults to $SING env var
```

`{user}` is expanded to `$USER` at runtime.

---

## Running the pipeline

### Step 0 — Generate transfer map CSVs from the database

Queries PostgreSQL and writes three CSVs to `STAGING_BASE_DIR`:
- `refgenomes_assembly_stats_{LABEL}_{DATE}.csv` — assembly QC stats for stage-3 OGs
- `hic_transfer_map_{LABEL}_{DATE}.csv` — OG → Hi-C tube ID mapping
- `draft_transfer_map_{LABEL}_{DATE}.csv` — draft workflow OGs

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
| `hic_transfer_map_*.csv` | CSV | OG ID → Hi-C library tube ID mapping |
| `draft_transfer_map_*.csv` | CSV | Draft workflow OG IDs and species names |
| `mitogenome_metadata_*.csv` | CSV | Mitogenome accession and metadata for all project OGs |

---

## Notes

- Run all scripts from the `get_data_package/` directory with the config file as the only argument.
- `RCLONE_FLAGS='--dry-run'` is useful for verifying what will be copied before running for real.
- Steps 01–05 are independent and can be re-run without affecting each other. Step 06 is destructive (removes intermediate staging dirs) — only run it once steps 01–05 are complete and the audit passes.
- Projects with no draft workflow OGs (reference-only) will skip steps 03 and 05 draft sections without error.
