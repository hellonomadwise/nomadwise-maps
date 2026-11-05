/**
 * listing_google: Search Console numbers for every listing page
 * (nomadwise.io/coworking/...) into Supabase, for the Performance tab
 * in the Owner account and the monthly email (migration 252).
 *
 * Lives in the "Nomadwise GSC feed" sheet's Apps Script as its own
 * file, next to pullGsc. Needs one Script Property, set by Jonathan:
 *   SUPABASE_SECRET_KEY  a secret key made for this script in Supabase
 *                        (Project Settings > API Keys > Secret keys,
 *                        name it "gsc-feed"). Never pasted anywhere else.
 *
 * Run once, by hand:   backfillListingGoogle  (the last 16 months)
 *                      createListingGoogleTrigger  (every morning)
 * Every morning:       pullListingGoogle  (last 10 days + searches)
 *
 * Writes nothing to the sheet except a stamp on the tab
 * "listing_google", so a stopped refresh is easy to spot.
 */

var LG_SITE = 'sc-domain:nomadwise.io';
var LG_SUPABASE = 'https://xclqfbuwrijpwtgbvrim.supabase.co';

function lgKey_() {
  var k = PropertiesService.getScriptProperties().getProperty('SUPABASE_SECRET_KEY');
  if (!k) throw new Error('Add the Script Property SUPABASE_SECRET_KEY first.');
  return k;
}

function lgDay_(d) {
  return Utilities.formatDate(d, 'UTC', 'yyyy-MM-dd');
}

/** Search Console rows for listing pages, all pages of results. */
function lgQuery_(start, end, dims) {
  var url = 'https://searchconsole.googleapis.com/webmasters/v3/sites/' +
    encodeURIComponent(LG_SITE) + '/searchAnalytics/query';
  var rows = [];
  var startRow = 0;
  while (true) {
    var body = {
      startDate: start,
      endDate: end,
      dimensions: dims,
      type: 'web',
      dataState: 'final',
      rowLimit: 25000,
      startRow: startRow,
      dimensionFilterGroups: [{ filters: [{
        dimension: 'page', operator: 'contains', expression: '/coworking/' }] }]
    };
    var res = UrlFetchApp.fetch(url, {
      method: 'post',
      contentType: 'application/json',
      headers: { Authorization: 'Bearer ' + ScriptApp.getOAuthToken() },
      payload: JSON.stringify(body),
      muteHttpExceptions: true
    });
    if (res.getResponseCode() !== 200) {
      throw new Error('Search Console: ' + res.getResponseCode() + ' ' + res.getContentText().slice(0, 300));
    }
    var got = JSON.parse(res.getContentText()).rows || [];
    rows = rows.concat(got);
    if (got.length < 25000) break;
    startRow += 25000;
  }
  return rows;
}

/** Sends day rows (and optionally searches) to Supabase. */
function lgSend_(days, queries) {
  var payload = { p_days: days };
  if (queries) payload.p_queries = queries;
  var res = UrlFetchApp.fetch(LG_SUPABASE + '/rest/v1/rpc/gsc_listing_import', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: lgKey_() },
    payload: JSON.stringify(payload),
    muteHttpExceptions: true
  });
  if (res.getResponseCode() !== 200) {
    throw new Error('Supabase: ' + res.getResponseCode() + ' ' + res.getContentText().slice(0, 300));
  }
  return JSON.parse(res.getContentText());
}

function lgDays_(start, end) {
  return lgQuery_(start, end, ['page', 'date']).map(function (r) {
    return { page: r.keys[0], day: r.keys[1], impressions: r.impressions, clicks: r.clicks };
  });
}

function lgStamp_(text) {
  var ss = SpreadsheetApp.getActive();
  var sh = ss.getSheetByName('listing_google') || ss.insertSheet('listing_google');
  sh.getRange(1, 1, 1, 2).setValues([['listing_google', 'Updated ' +
    Utilities.formatDate(new Date(), 'Europe/London', 'yyyy-MM-dd HH:mm') + ' ' + text]]);
}

/** Every morning: the last 10 final days, and the searches of the last 90. */
function pullListingGoogle() {
  var end = new Date(Date.now() - 3 * 86400000);
  var from = new Date(end.getTime() - 9 * 86400000);
  var from90 = new Date(end.getTime() - 89 * 86400000);
  var days = lgDays_(lgDay_(from), lgDay_(end));
  var queries = lgQuery_(lgDay_(from90), lgDay_(end), ['page', 'query']).map(function (r) {
    return { page: r.keys[0], query: r.keys[1], impressions: r.impressions, clicks: r.clicks };
  });
  var out = lgSend_(days, queries);
  lgStamp_('(' + out.day_rows + ' day rows, ' + out.pages + ' pages, ' +
    out.query_rows + ' searches, up to ' + out.last_day + ')');
}

/** Once: the last 16 months, one month at a time. */
function backfillListingGoogle() {
  var end = new Date(Date.now() - 3 * 86400000);
  var total = 0;
  for (var m = 0; m < 16; m++) {
    var to = new Date(end.getTime() - m * 30 * 86400000);
    var from = new Date(to.getTime() - 29 * 86400000);
    var days = lgDays_(lgDay_(from), lgDay_(to));
    if (days.length) total += lgSend_(days, null).day_rows;
  }
  pullListingGoogle();
  lgStamp_('(backfill: ' + total + ' day rows)');
}

/** Once: run pullListingGoogle every morning at about 06:45. */
function createListingGoogleTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'pullListingGoogle') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('pullListingGoogle').timeBased().atHour(6).nearMinute(45)
    .everyDays(1).inTimezone('Europe/London').create();
}
