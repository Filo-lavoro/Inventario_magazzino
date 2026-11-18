#!/usr/bin/env python3
"""Importa l'inventario Excel nel database Supabase."""
import argparse
import os
import re
import sys
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

import openpyxl
import requests

ALIASES = {
    "name": {"nome", "name", "prodotto"},
    "manufacturer": {"produttore", "manufacturer", "marca"},
    "format": {"formato", "format"},
    "weight": {"peso", "weight"},
    "lot_code": {"lotto", "lot"},
    "expires_on": {"scadenza", "expiry"},
    "piece_count": {"n pezzi", "numero pezzi", "pezzi", "piece count"},
    "quantity": {"quantità", "quantita", "quantity"},
}
BATCH_SIZE = 500


def clean(value):
    value = str(value).strip() if value is not None else ""
    return value or None


def as_number(value):
    if value in (None, ""):
        return None
    try:
        return str(Decimal(str(value).replace(",", ".")))
    except InvalidOperation:
        return None


def as_date(value):
    if value in (None, ""):
        return None
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, (int, float)):
        return openpyxl.utils.datetime.from_excel(value).date().isoformat()
    for fmt in ("%d/%m/%Y", "%Y-%m-%d", "%d-%m-%Y"):
        try:
            return datetime.strptime(str(value).strip(), fmt).date().isoformat()
        except ValueError:
            pass
    return None


def find_headers(sheet):
    for row_number in range(1, min(sheet.max_row, 30) + 1):
        values = [re.sub(r"\s+", " ", str(c.value or "").strip().lower())
                  for c in sheet[row_number]]
        columns = {}
        for field, aliases in ALIASES.items():
            for index, value in enumerate(values, 1):
                if value in aliases:
                    columns[field] = index
                    break
        if {"name", "lot_code", "expires_on", "piece_count", "quantity"} <= columns.keys():
            return row_number, columns
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbook", help="Percorso al file Excel")
    args = parser.parse_args()
    base = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not base or not key:
        parser.error("Imposta SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY localmente.")
    headers = {"apikey": key, "Authorization": f"Bearer {key}",
               "Content-Type": "application/json", "Prefer": "return=representation"}

    def get(table, params):
        response = requests.get(f"{base}/rest/v1/{table}", headers=headers,
                                params=params, timeout=90)
        response.raise_for_status()
        return response.json()

    def insert(table, rows):
        response = requests.post(f"{base}/rest/v1/{table}", headers=headers,
                                 json=rows, timeout=90)
        response.raise_for_status()
        return response.json()

    book = openpyxl.load_workbook(args.workbook, read_only=True, data_only=True)
    total = 0
    for order, sheet in enumerate(book.worksheets):
        detected = find_headers(sheet)
        if not detected:
            print(f"Saltato: {sheet.title} (intestazioni non riconosciute)")
            continue
        first_row, columns = detected
        categories = get("inventory_categories", {
            "select": "id", "name": f"eq.{sheet.title.strip()}"})
        if categories:
            category_id = categories[0]["id"]
        else:
            category_id = insert("inventory_categories", [{
                "name": sheet.title.strip(), "sort_order": order}])[0]["id"]
        products = get("products", {
            "select": "id,name,manufacturer,format,weight",
            "category_id": f"eq.{category_id}"})
        cache = {(p["name"], p["manufacturer"], p["format"], as_number(p["weight"])): p["id"]
                 for p in products}
        lots = []
        for row_number, row in enumerate(
                sheet.iter_rows(min_row=first_row + 1, values_only=True), first_row + 1):
            def value(field):
                index = columns.get(field, 0) - 1
                return row[index] if 0 <= index < len(row) else None

            name = clean(value("name"))
            if not name:
                continue
            manufacturer, fmt = clean(value("manufacturer")), clean(value("format"))
            weight = as_number(value("weight"))
            identity = (name, manufacturer, fmt, weight)
            product_id = cache.get(identity)
            if product_id is None:
                product_id = insert("products", [{
                    "name": name, "manufacturer": manufacturer,
                    "category_id": category_id, "format": fmt, "weight": weight}])[0]["id"]
                cache[identity] = product_id
            lots.append({
                "product_id": product_id, "lot_code": clean(value("lot_code")),
                "expires_on": as_date(value("expires_on")),
                "piece_count": as_number(value("piece_count")),
                "quantity": as_number(value("quantity")),
                "source_sheet": sheet.title, "source_row": row_number})
            if len(lots) >= BATCH_SIZE:
                insert("inventory_lots", lots)
                total += len(lots)
                lots.clear()
        if lots:
            insert("inventory_lots", lots)
            total += len(lots)
        print(f"{sheet.title}: completato")
    book.close()
    print(f"Importazione terminata: {total} lotti")


if __name__ == "__main__":
    try:
        main()
    except requests.HTTPError as error:
        print(f"Errore Supabase: {error.response.status_code} {error.response.text}",
              file=sys.stderr)
        raise SystemExit(1)
