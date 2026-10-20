#!/usr/bin/env python3
"""
One-command database setup for the IAPMQ project. Works on Windows, macOS and Linux.

    python setup_db.py

What it does
  1. Connects to PostgreSQL using the DATABASE_URL environment variable
     (default: postgresql+psycopg2://postgres@localhost:5432/iapmq).
  2. Creates the database if it does not exist.
  3. Runs sql/01_schema.sql, then sql/02_import.sql (loading the CSVs in data/).

It needs only the Python packages in requirements.txt -- NOT the psql command-line tool.
It can be run from any folder, and it is safe to run again: the schema script drops and
rebuilds every table.

Example DATABASE_URL values
  postgresql+psycopg2://postgres:YOUR_PASSWORD@localhost:5432/iapmq
  postgresql+psycopg2://myuser:YOUR_PASSWORD@localhost:5432/iapmq
If the password has special characters (@ : / # %), URL-encode them (e.g. @ -> %40).
"""
import os
import re
import sys
from pathlib import Path

import psycopg2
from psycopg2 import sql as pgsql
from sqlalchemy.engine import make_url

ROOT = Path(__file__).resolve().parent
DEFAULT_URL = "postgresql+psycopg2://postgres@localhost:5432/iapmq"

# Matches the psql meta-command used in 02_import.sql:
#   \copy table FROM 'relative/path.csv' WITH (...)
COPY_RE = re.compile(r"^\\copy\s+(\w+)\s+FROM\s+'([^']+)'\s+WITH\s+\((.*)\)\s*$", re.IGNORECASE)


def connect_kwargs(url, dbname=None):
    kw = {"dbname": dbname or url.database, "user": url.username, "password": url.password,
          "host": url.host or url.query.get("host"), "port": url.port or url.query.get("port")}
    return {k: v for k, v in kw.items() if v is not None}


def ensure_database(url):
    conn = psycopg2.connect(**connect_kwargs(url, "postgres"))
    conn.autocommit = True          # CREATE DATABASE cannot run inside a transaction
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (url.database,))
            if cur.fetchone():
                print(f"Database '{url.database}' already exists.")
            else:
                cur.execute(pgsql.SQL("CREATE DATABASE {}").format(pgsql.Identifier(url.database)))
                print(f"Created database '{url.database}'.")
    finally:
        conn.close()


def run_script(conn, path):
    """Run a .sql file. Lines starting with \\copy (a psql command) are executed as COPY
    ... FROM STDIN so no psql installation is needed; everything else runs as plain SQL."""
    chunk = []
    last_result = None

    def flush():
        nonlocal last_result
        text = "\n".join(chunk).strip()
        has_sql = any(l.strip() and not l.strip().startswith("--") for l in chunk)
        chunk.clear()
        if not has_sql:        # nothing but comments / blank lines
            return
        with conn.cursor() as cur:
            cur.execute(text)
            if cur.description:
                last_result = (cur.description, cur.fetchall())

    for line in path.read_text(encoding="utf-8").splitlines():
        m = COPY_RE.match(line.strip())
        if not m:
            chunk.append(line)
            continue
        flush()
        table, rel_path, options = m.groups()
        with conn.cursor() as cur, open(ROOT / rel_path, "rb") as f:
            cur.copy_expert(f"COPY {table} FROM STDIN WITH ({options})", f)
            print(f"  loaded {rel_path} -> {table} ({cur.rowcount} rows)")
    flush()
    return last_result


def main():
    url = make_url(os.environ.get("DATABASE_URL", DEFAULT_URL))
    if not url.database:
        sys.exit("DATABASE_URL must include a database name, e.g. .../iapmq")
    try:
        ensure_database(url)
        conn = psycopg2.connect(**connect_kwargs(url))
    except psycopg2.OperationalError as e:
        sys.exit(f"\nCould not connect to PostgreSQL:\n{e}\n"
                 "Check that the server is running and set DATABASE_URL with your user, password, "
                 "host and port (see the README, section 'Set up on your computer').")
    conn.set_client_encoding("UTF8")
    try:
        for name in ("01_schema.sql", "02_import.sql"):
            print(f"Running sql/{name} ...")
            result = run_script(conn, ROOT / "sql" / name)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    if result:
        print("\nRow counts:")
        for table, n in result[1]:
            print(f"  {table:<28}{n:>6}")
    print("\nDone. Try: python viz/make_charts.py   (charts)  or open sql/03_queries.sql in your SQL client.")


if __name__ == "__main__":
    main()
