# Inventario Magazzino Grundy

Progetto per gestire l’inventario Excel in Supabase.

## Modello dati

- `inventory_categories`: una categoria per foglio.
- `products`: anagrafica con nome, produttore, formato e peso.
- `inventory_lots`: lotto, scadenza, numero pezzi e quantità; conserva foglio e riga sorgente.
- `inventory_stock`: vista con flag `is_expired` calcolato sulla data corrente.

RLS è attivo. L’importatore richiede `SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` nell’ambiente locale; non inserire chiavi nel repository.

Installa `requirements.txt`, poi esegui `python scripts/import_inventory.py "percorso\Inventario Magazzino Grundy.xlsx"`.

La migrazione è in `supabase/migrations/20261118000000_create_inventory_schema.sql`.
