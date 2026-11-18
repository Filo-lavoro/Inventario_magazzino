# Attivazione Gmail → Supabase

Il codice in Code.gs controlla ogni 5 minuti i thread con etichetta Gmail **Richiesta prodotti**. La richiesta viene conteggiata solo se il testo contiene righe con nome prodotto esatto e quantità, per esempio:

- PHYSIOLOGIC | 2 pezzi

Messaggi ambigui o con scorte insufficienti vengono spostati nelle rispettive etichette di verifica. Il codice non invia email. Importa prima l’inventario Excel: le tabelle Supabase al momento non contengono prodotti o lotti.

## Configurazione una tantum

1. Apri https://script.google.com/ e crea un progetto Apps Script.
2. Copia il contenuto di Code.gs nell’editor.
3. In Impostazioni progetto → Proprietà script, aggiungi:
   - SUPABASE_URL = https://zrowrdcvizomrdzwhfex.supabase.co
   - SUPABASE_SERVICE_ROLE_KEY = chiave server-side Supabase
4. Non mettere la chiave in questo repository o nel codice; le proprietà dello script restano nell’account Google.
5. Seleziona installFiveMinuteTrigger nell’editor Apps Script, eseguila una volta e autorizza l’accesso a Gmail e alle richieste esterne.
6. Applica manualmente l’etichetta Richiesta prodotti ai messaggi validi. Il codice non deduce automaticamente quali mittenti o email siano ordini.

Il database registra l’ID Gmail una sola volta, scala per primi i lotti con scadenza più vicina (FEFO) e non consente una sottrazione parziale se la giacenza complessiva non basta. La quantità viene ridotta in proporzione alle unità sottratte.
