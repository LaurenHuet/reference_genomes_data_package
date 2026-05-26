#!/usr/bin/env python3
"""
pull_genome_statistics_by_project.py

Reads PROJECT_ID (or OG_ID) and POSTGRES_CFG and STAGING_BASE_DIR from a single
bash-style KEY=VALUE config file, queries OceanOmics Postgres, and writes:

1) Assembly stats CSV:
   {STAGING_BASE_DIR}/refgenomes_assembly_stats_{LABEL}_{YYYYMMDD}.csv

2) Hi-C transfer map CSV (one row per og_id x hic_library_tube_id):
   {STAGING_BASE_DIR}/hic_transfer_map_{LABEL}_{YYYYMMDD}.csv

Scope options (set one in config):
  PROJECT_ID='OGP047'              — all OGs in that project
  OG_ID='OG1234'                   — specific OG (or comma-separated list)

Run:
  singularity run $SING2/psycopg2:0.1.sif python pull_genome_statistics_by_project.py refgenomes_data_package.conf
"""

from __future__ import annotations

import os
import sys
import getpass
import configparser
from pathlib import Path
from datetime import date
from typing import Dict

import pandas as pd
import psycopg2


def load_kv_config(path: str) -> Dict[str, str]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"❌ Config file does not exist: {path}")

    cfg: Dict[str, str] = {}
    for raw in p.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        if not k:
            continue
        if v.startswith(("'", '"')):
            q = v[0]
            end = v.find(q, 1)
            v = v[1:end] if end != -1 else v[1:]
        else:
            # strip trailing inline comment (whitespace + #)
            import re
            v = re.sub(r'\s+#.*$', '', v)
        cfg[k] = v
    return cfg


def require(cfg: Dict[str, str], key: str) -> str:
    if key not in cfg or cfg[key].strip() == "":
        raise ValueError(f"❌ Missing required config key: {key}")
    return cfg[key].strip()


def expand_placeholders(s: str, user: str, label: str) -> str:
    return (
        s.replace("{user}", user)
        .replace("${PROJECT_ID}", label)
        .replace("{PROJECT_ID}", label)
        .replace("${OG_ID}", label)
        .replace("{OG_ID}", label)
    )


def read_postgres_ini(postgres_cfg_path: str) -> Dict[str, str]:
    """
    Read Postgres connection details from an INI file with section [postgres].
    Required keys: dbname, user, password, host
    Optional: port
    """
    postgres_cfg_path = os.path.expanduser(postgres_cfg_path)
    if not os.path.exists(postgres_cfg_path):
        raise FileNotFoundError(f"❌ Postgres config not found: {postgres_cfg_path}")

    pg = configparser.ConfigParser()
    pg.read(postgres_cfg_path)

    if "postgres" not in pg:
        raise ValueError(f"❌ Missing [postgres] section in {postgres_cfg_path}")

    section = pg["postgres"]
    for k in ("dbname", "user", "password", "host"):
        if k not in section or section[k].strip() == "":
            raise ValueError(f"❌ Missing '{k}' in [postgres] section of {postgres_cfg_path}")

    return {
        "dbname": section["dbname"].strip(),
        "user": section["user"].strip(),
        "password": section["password"].strip(),
        "host": section["host"].strip(),
        "port": section.get("port", "5432").strip(),
    }


# These exact strings appear in each SQL CTE and are replaced for OG_ID mode.
_PROJECT_CTE_STD = (
    "  SELECT s.og_id\n"
    "  FROM sample s\n"
    "  WHERE s.project_id = %s"
)
_PROJECT_CTE_DRAFT = (
    "  SELECT s.og_id\n"
    "  FROM sample s\n"
    "  WHERE s.project_id = %s\n"
    "    AND lower(btrim(s.workflow)) = 'draft'"
)
_OG_CTE = (
    "  SELECT DISTINCT s.og_id\n"
    "  FROM sample s\n"
    "  WHERE s.og_id = ANY(%s::text[])"
)


def _apply_og_mode(sql: str) -> str:
    """Rewrite the og_ids CTE to filter by a list of og_ids instead of project_id."""
    # Replace DRAFT variant first (it's a superset of STD, so STD must come second)
    return sql.replace(_PROJECT_CTE_DRAFT, _OG_CTE).replace(_PROJECT_CTE_STD, _OG_CTE)


STATS_SQL = """
WITH og_ids AS (
  SELECT s.og_id
  FROM sample s
  WHERE s.project_id = %s
),
nominal AS (
  SELECT og_id, MAX(nominal_species_id) AS nominal_species_id
  FROM sample
  GROUP BY og_id
),
lca_one AS (
  SELECT
    lv.og_id,
    COALESCE(
      MAX(lv.validated_species_name) FILTER (
        WHERE lower(lv.tech) = 'hifi'
          AND lv.validated_species_name IS NOT NULL
          AND btrim(lv.validated_species_name) <> ''
      ),
      MAX(lv.validated_species_name) FILTER (
        WHERE lower(lv.tech) = 'hic'
          AND lv.validated_species_name IS NOT NULL
          AND btrim(lv.validated_species_name) <> ''
      ),
      ''
    ) AS validated_species_name
  FROM lca_validation lv
  GROUP BY lv.og_id
)
SELECT
  rg.og_id                       AS "Sample",
  NULLIF(COALESCE(
    NULLIF(btrim(lca_one.validated_species_name), ''),
    NULLIF(btrim(n.nominal_species_id::text), '')
  ), '')                         AS "Species ID",
  rg.haplotype                   AS "Haplotype",
  rg.sum_len                     AS "Assembly Size",
  rg.num_scaffolds               AS "Number of Scaffolds",
  rg.scaffold_n50_size_mb        AS "Scaffold n50 (mb)",
  rg.contig_n50_size_mb          AS "Contig n50 (mb)",
  rg.complete                    AS "BUSCO completeness",
  rg.qv                          AS "Merqury qv",
  rg.completeness                AS "Merqury completeness",
  rg.num_chromosomes             AS "Number of Chromosomes",
  rg.pct_assigned                AS "Assembly assigned to chromosome (%%)"
FROM ref_genomes rg
JOIN og_ids o
  ON o.og_id = rg.og_id
LEFT JOIN lca_one
  ON lca_one.og_id = rg.og_id
LEFT JOIN nominal n
  ON n.og_id = rg.og_id
WHERE rg.stage = 3
ORDER BY
  rg.og_id,
  CASE rg.haplotype
    WHEN 'hap1' THEN 1
    WHEN 'hap2' THEN 2
    WHEN 'dual' THEN 3
    ELSE 99
  END;
""".strip()


HIC_MAP_SQL = """
WITH og_ids AS (
  SELECT s.og_id
  FROM sample s
  WHERE s.project_id = %s
),
nominal AS (
  SELECT og_id, MAX(nominal_species_id) AS nominal_species_id
  FROM sample
  GROUP BY og_id
),
lca_one AS (
  SELECT
    lv.og_id,
    COALESCE(
      MAX(lv.validated_species_name) FILTER (
        WHERE lower(lv.tech) = 'hifi'
          AND lv.validated_species_name IS NOT NULL
          AND btrim(lv.validated_species_name) <> ''
      ),
      MAX(lv.validated_species_name) FILTER (
        WHERE lower(lv.tech) = 'hic'
          AND lv.validated_species_name IS NOT NULL
          AND btrim(lv.validated_species_name) <> ''
      ),
      ''
    ) AS validated_species_name
  FROM lca_validation lv
  GROUP BY lv.og_id
)
SELECT
  o.og_id                        AS og_id,
  NULLIF(COALESCE(
    NULLIF(btrim(lca_one.validated_species_name), ''),
    NULLIF(btrim(n.nominal_species_id::text), '')
  ), '')                         AS species_id,
  seq.hic_library_tube_id        AS hic_library_tube_id
FROM og_ids o
JOIN sequencing seq
  ON seq.og_id = o.og_id
LEFT JOIN lca_one
  ON lca_one.og_id = o.og_id
LEFT JOIN nominal n
  ON n.og_id = o.og_id
WHERE seq.hic_library_tube_id IS NOT NULL
  AND btrim(seq.hic_library_tube_id) <> ''
ORDER BY o.og_id, seq.hic_library_tube_id;
""".strip()


DRAFT_MAP_SQL = """
WITH og_ids AS (
  SELECT s.og_id
  FROM sample s
  WHERE s.project_id = %s
    AND lower(btrim(s.workflow)) = 'draft'
),
nominal AS (
  SELECT og_id, MAX(nominal_species_id) AS nominal_species_id
  FROM sample
  GROUP BY og_id
),
lca_one AS (
  SELECT
    lv.og_id,
    COALESCE(
      MAX(lv.validated_species_name) FILTER (
        WHERE lower(lv.tech) = 'ilmn'
          AND lv.validated_species_name IS NOT NULL
          AND btrim(lv.validated_species_name) <> ''
      ),
      MAX(lv.validated_species_name) FILTER (
        WHERE lv.validated_species_name IS NOT NULL
          AND btrim(lv.validated_species_name) <> ''
      ),
      ''
    ) AS validated_species_name
  FROM lca_validation lv
  GROUP BY lv.og_id
)
SELECT
  o.og_id                                        AS og_id,
  NULLIF(COALESCE(
    NULLIF(btrim(lca_one.validated_species_name), ''),
    NULLIF(btrim(n.nominal_species_id::text), '')
  ), '')                                         AS species_id,
  NULLIF(btrim(n.nominal_species_id::text), '')  AS nominal_species_id
FROM og_ids o
LEFT JOIN lca_one ON lca_one.og_id = o.og_id
LEFT JOIN nominal n ON n.og_id = o.og_id
ORDER BY o.og_id;
""".strip()


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: pull_genome_statistics_by_project.py <refgenomes_datapackage.conf>", file=sys.stderr)
        sys.exit(1)

    conf_path = sys.argv[1]
    cfg = load_kv_config(conf_path)

    user = os.environ.get("USER") or getpass.getuser()
    user = user.replace("'", "").replace("/", "")

    project_id = cfg.get("PROJECT_ID", "").strip()
    og_id_raw = cfg.get("OG_ID", "").strip()

    if og_id_raw:
        og_ids_list = [x.strip() for x in og_id_raw.split(",") if x.strip()]
        package_name = cfg.get("PACKAGE_NAME", "").strip()
        if not package_name:
            print("❌ PACKAGE_NAME must be set in config when using OG_ID mode", file=sys.stderr)
            sys.exit(1)
        label = package_name
        db_param: object = og_ids_list
    elif project_id:
        label = project_id
        db_param = project_id
    else:
        print("❌ Either PROJECT_ID or OG_ID must be set in config", file=sys.stderr)
        sys.exit(1)

    postgres_cfg = require(cfg, "POSTGRES_CFG")
    staging_base_dir = require(cfg, "STAGING_BASE_DIR")

    postgres_cfg = expand_placeholders(postgres_cfg, user, label)
    staging_base_dir = expand_placeholders(staging_base_dir, user, label).rstrip("/")

    pg = read_postgres_ini(postgres_cfg)

    Path(staging_base_dir).mkdir(parents=True, exist_ok=True)

    today = date.today().strftime("%Y%m%d")
    out_stats = str(Path(staging_base_dir) / f"refgenomes_assembly_stats_{label}_{today}.csv")
    out_hic = str(Path(staging_base_dir) / f"hic_transfer_map_{label}_{today}.csv")

    conn = None
    cur = None
    try:
        conn = psycopg2.connect(
            dbname=pg["dbname"],
            user=pg["user"],
            password=pg["password"],
            host=pg["host"],
            port=int(pg["port"]),
        )
        cur = conn.cursor()

        stats_sql = _apply_og_mode(STATS_SQL) if og_id_raw else STATS_SQL
        hic_sql = _apply_og_mode(HIC_MAP_SQL) if og_id_raw else HIC_MAP_SQL
        draft_sql = _apply_og_mode(DRAFT_MAP_SQL) if og_id_raw else DRAFT_MAP_SQL

        # --- Assembly stats ---
        cur.execute(stats_sql, (db_param,))
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description]
        df = pd.DataFrame(rows, columns=cols)
        df.to_csv(out_stats, index=False)
        print(f"✅ Wrote assembly stats CSV: {out_stats}")

        # --- Hi-C transfer map (all tube IDs) ---
        cur.execute(hic_sql, (db_param,))
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description]
        hic_df = pd.DataFrame(rows, columns=cols)
        hic_df.to_csv(out_hic, index=False)
        print(f"✅ Wrote Hi-C transfer map CSV: {out_hic}")

        # --- Draft genome map ---
        out_draft = str(Path(staging_base_dir) / f"draft_transfer_map_{label}_{today}.csv")
        cur.execute(draft_sql, (db_param,))
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description]
        draft_df = pd.DataFrame(rows, columns=cols)
        draft_df.to_csv(out_draft, index=False)
        print(f"✅ Wrote draft transfer map CSV: {out_draft}")

        # Print OG IDs (from stats df)
        if "Sample" in df.columns and not df.empty:
            ogs = df["Sample"].dropna().astype(str).unique().tolist()
            print("\n# OG IDs in project:")
            for og in ogs:
                print(og)

    finally:
        if cur is not None:
            cur.close()
        if conn is not None:
            conn.close()


if __name__ == "__main__":
    main()
