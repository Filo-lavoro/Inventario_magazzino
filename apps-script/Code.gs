/** Gmail -> Supabase inventory synchronizer.
 * Only threads labeled "Richiesta prodotti" are examined.
 * Expected body lines: - PRODUCT NAME | 2 pezzi
 * Ambiguous/unparseable requests are routed to a review label, never deducted.
 */
const REQUEST_LABEL = 'Richiesta prodotti';
const DONE_LABEL = 'Richiesta prodotti/Elaborate';
const REVIEW_LABEL = 'Richiesta prodotti/Da verificare';
const STOCK_LABEL = 'Richiesta prodotti/Scorte insufficienti';
const BATCH_SIZE = 100;

function processProductRequests() {
  const props = PropertiesService.getScriptProperties();
  const baseUrl = (props.getProperty('SUPABASE_URL') || '').replace(/\/$/, '');
  const serviceKey = props.getProperty('SUPABASE_SERVICE_ROLE_KEY');
  if (!baseUrl || !serviceKey) throw new Error('Impostare SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY nelle proprietà dello script.');

  const requestLabel = GmailApp.getUserLabelByName(REQUEST_LABEL);
  if (!requestLabel) throw new Error('Etichetta Gmail mancante: ' + REQUEST_LABEL);
  const doneLabel = getOrCreateLabel_(DONE_LABEL);
  const reviewLabel = getOrCreateLabel_(REVIEW_LABEL);
  const stockLabel = getOrCreateLabel_(STOCK_LABEL);
  const threads = requestLabel.getThreads(0, BATCH_SIZE);

  threads.forEach(function(thread) {
    const messages = thread.getMessages();
    if (!messages.length) return;
    // Gmail labels are thread-level; use only the latest message in the labeled thread.
    const message = messages[messages.length - 1];
    const items = parseItems_(message.getPlainBody());
    const response = UrlFetchApp.fetch(baseUrl + '/rest/v1/rpc/process_gmail_product_request', {
      method: 'post',
      contentType: 'application/json',
      headers: { apikey: serviceKey, Authorization: 'Bearer ' + serviceKey },
      payload: JSON.stringify({
        p_gmail_message_id: message.getId(),
        p_received_at: message.getDate().toISOString(),
        // An unparseable request is recorded as needs_review by the database function.
        p_items: items.length ? items : [{ name: '', quantity: null }]
      }),
      muteHttpExceptions: true
    });
    if (response.getResponseCode() < 200 || response.getResponseCode() >= 300) {
      throw new Error('Supabase RPC error ' + response.getResponseCode() + ': ' + response.getContentText());
    }
    const result = JSON.parse(response.getContentText());
    const status = result.status === 'duplicate' ? result.existing_status : result.status;
    if (status === 'processed') {
      moveThread_(thread, requestLabel, doneLabel);
    } else if (status === 'needs_review') {
      moveThread_(thread, requestLabel, reviewLabel);
    } else if (status === 'insufficient_stock') {
      moveThread_(thread, requestLabel, stockLabel);
    }
    console.log('Gmail message ' + message.getId() + ': ' + status);
  });
}

function parseItems_(body) {
  const items = [];
  const lines = String(body || '').split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (/^(>|On .+ wrote:|Il giorno .+ ha scritto:)/i.test(line)) break;
    const match = line.match(/^[-*•]?\s*(.+?)\s*(?:\||;|—|-)\s*(\d+)\s*(?:pz|pezzi)\s*$/i);
    if (!match) continue;
    items.push({ name: match[1].trim(), quantity: Number(match[2]) });
  }
  return items;
}

function getOrCreateLabel_(name) {
  return GmailApp.getUserLabelByName(name) || GmailApp.createLabel(name);
}

function moveThread_(thread, fromLabel, toLabel) {
  thread.addLabel(toLabel);
  thread.removeLabel(fromLabel);
}

// Run once from the Apps Script editor after setting Script Properties and authorizing Gmail.
function installFiveMinuteTrigger() {
  const exists = ScriptApp.getProjectTriggers().some(function(trigger) {
    return trigger.getHandlerFunction() === 'processProductRequests';
  });
  if (!exists) ScriptApp.newTrigger('processProductRequests').timeBased().everyMinutes(5).create();
}
