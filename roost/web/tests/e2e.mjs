// End-to-end test of the web app against a real roost-server.
//
//   ROOST_E2E_URL=http://127.0.0.1:8097/h/test-family/ node tests/e2e.mjs
//
// The server must be fresh (no families yet). Screenshots go to ../docs/screenshots.
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

// Seed data in the same zone the browser contexts use.
process.env.TZ = 'America/Chicago';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const APP = process.env.ROOST_E2E_URL ?? 'http://127.0.0.1:8097/h/test-family/';
const ORIGIN = new URL(APP).origin;
const SHOTS = fileURLToPath(new URL('../../docs/screenshots/', import.meta.url));
mkdirSync(SHOTS, { recursive: true });
const PW = 'correct-horse-1';
const log = (...a) => console.log('•', ...a);

async function api(path, { token, method = 'GET', body } = {}) {
  const res = await fetch(ORIGIN + path, {
    method, headers: { 'content-type': 'application/json', ...(token ? { authorization: token } : {}) }, body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${text}`);
  return text ? JSON.parse(text) : {};
}
const login = async (email) => (await api('/api/collections/users/auth-with-password', { method: 'POST', body: { identity: email, password: PW } })).token;
const list = async (coll, token, filter = '') => (await api(`/api/collections/${coll}/records?perPage=500${filter ? '&filter=' + encodeURIComponent(filter) : ''}`, { token })).items;
const create = (coll, token, body) => api(`/api/collections/${coll}/records`, { token, method: 'POST', body });

// Local wall time → ISO for the browser's zone (tests run in America/Chicago).
function at(dayOffset, h, m = 0) {
  const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() + dayOffset); d.setHours(h, m, 0, 0);
  return d.toISOString();
}
const weekdayOffset = (wd) => ((wd - new Date().getDay() + 7) % 7); // next given weekday (0 = today if matching)

const browser = await chromium.launch();
const desktop = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, timezoneId: 'America/Chicago', locale: 'en-US' };
const phone = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, timezoneId: 'America/Chicago', locale: 'en-US' };
const shot = (page, name) => page.screenshot({ path: SHOTS + name + '.jpg', type: 'jpeg', quality: 82 });

try {
  // ---------------------------------------------------------------- owner onboarding
  const ctx = await browser.newContext(desktop);
  const page = await ctx.newPage();
  const consoleErrors = [];
  page.on('pageerror', (e) => consoleErrors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource|ERR_|404/.test(m.text())) consoleErrors.push(m.text()); });

  await page.goto(APP);
  await page.getByRole('button', { name: 'Start a new family' }).click();
  await page.getByLabel('Your name').fill('Alex Rivera');
  await page.getByLabel('Email').fill('alex@example.com');
  await page.getByLabel('Password (8+ characters)').fill(PW);
  await page.getByLabel('Family name').fill('The Riveras');
  await shot(page, '01-create-family');
  await page.getByRole('button', { name: 'Create family' }).click();
  await page.getByRole('heading', { name: /Good (morning|afternoon|evening), Alex/ }).waitFor();
  log('owner created family and landed on Today');

  // ---------------------------------------------------------------- seed a realistic family via API
  const owner = await login('alex@example.com');
  const fam = (await list('families', owner))[0];
  const me = (await list('memberships', owner))[0];
  const cals = await list('calendars', owner);
  const famCal = cals.find((c) => c.kind === 'family'), alexCal = cals.find((c) => c.kind === 'personal');
  const lists = await list('lists', owner);
  const todo = lists.find((l) => l.kind === 'todo'), grocery = lists.find((l) => l.kind === 'grocery');
  const mk = async (name, role, color, emoji = '') => (await create('memberships', owner, { family: fam.id, name, role, color, emoji })).id;
  const emma = await mk('Emma', 'kid', 'pink', ''), leo = await mk('Leo', 'kid', 'green', '');
  await api(`/api/collections/memberships/records/${me.id}`, { token: owner, method: 'PATCH', body: { color: 'blue' } });

  // Invite co-parent Sam, nanny Maria and Grandma via the real flow.
  const invite = async (role, name) => (await create('invites', owner, { family: fam.id, role, name })).code;
  const join = async (email, name, code) => {
    await api('/api/collections/users/records', { method: 'POST', body: { email, name, password: PW, passwordConfirm: PW, inviteCode: code } });
    const t = await login(email);
    await api('/api/roost/join', { token: t, method: 'POST', body: { code } });
    return t;
  };
  const sam = await join('sam@example.com', 'Sam', await invite('parent', 'Sam'));
  const samM = (await list('memberships', owner, "name = 'Sam'"))[0].id;
  await api(`/api/collections/memberships/records/${samM}`, { token: owner, method: 'PATCH', body: { color: 'violet' } });
  await join('grandma@example.com', 'Grandma Jo', await invite('relative', 'Grandma Jo'));
  const nannyCode = await invite('caregiver', 'Maria');

  const ev = (o) => create('events', owner, { tz: 'America/Chicago', reminders: [30], ...o });
  const tue = weekdayOffset(2), wed = weekdayOffset(3), thu = weekdayOffset(4), fri = weekdayOffset(5), sat = weekdayOffset(6);
  await ev({ calendar: famCal.id, title: 'Soccer practice', start: at(tue, 16), end: at(tue, 17, 30), rrule: 'FREQ=WEEKLY;BYDAY=TU,TH', members: [emma], driver: samM, location: 'Riverside Park field 3' });
  await ev({ calendar: famCal.id, title: 'Piano lesson', start: at(wed, 15, 30), end: at(wed, 16, 15), rrule: 'FREQ=WEEKLY', members: [leo], location: 'Ms. Chen’s studio' });
  await ev({ calendar: famCal.id, title: 'Pediatrician — Leo checkup', start: at(fri, 10), end: at(fri, 10, 45), members: [leo], driver: me.id, location: 'Lakeside Pediatrics' });
  await ev({ calendar: famCal.id, title: 'Swim lessons', start: at(sat, 9), end: at(sat, 10), rrule: 'FREQ=WEEKLY;BYDAY=SA', members: [emma, leo] });
  await ev({ calendar: famCal.id, title: 'Thanksgiving at Grandma’s', start: at(thu, 0), end: at(thu + 1, 0), allDay: true, members: [emma, leo, me.id, samM] });
  await ev({ calendar: famCal.id, title: 'School holiday concert', start: at(10, 18), end: at(10, 19, 30), members: [emma, leo] });
  await ev({ calendar: famCal.id, title: 'Library story time', start: at(0, 10), end: at(0, 11), members: [leo] });
  await ev({ calendar: famCal.id, title: 'Dinner with the Parks', start: at(0, 18, 30), end: at(0, 20), members: [me.id, samM] });
  await ev({ calendar: famCal.id, title: 'Date night', start: at(sat, 19), end: at(sat, 22), members: [me.id, samM], private: true });
  await ev({ calendar: alexCal.id, title: 'Clinic', start: at(1, 8), end: at(1, 17), rrule: 'FREQ=WEEKLY;BYDAY=MO,TU,WE', members: [me.id] });
  await ev({ calendar: alexCal.id, title: 'Dermatology board review', start: at(fri, 13), end: at(fri, 15), members: [me.id] });
  const task = (o) => create('tasks', owner, { list: todo.id, ...o });
  const today = new Date(); const key = (n) => { const d = new Date(today); d.setDate(d.getDate() + n); return d.toLocaleDateString('en-CA'); };
  await task({ title: 'Sign Emma’s field trip permission slip', due: key(0), assignees: [me.id], priority: 2 });
  await task({ title: 'Order birthday gift for Leo’s friend', due: key(fri), priority: 1 });
  await task({ title: 'Book flights for winter break', due: key(6), assignees: [samM] });
  await task({ title: 'Take out recycling', due: key(1), rrule: 'FREQ=WEEKLY', assignees: [samM] });
  await task({ title: 'Renew passports', priority: 3 });
  const pickup = await task({ title: 'Pick up Leo’s prescription', due: `${key(1)}T15:00`, reminders: [30] });
  await create('infoCards', owner, { family: fam.id, title: 'Pediatrician', kind: 'contact', phone: '(555) 201-4400', address: '1200 Lakeside Dr', body: 'Dr. Okafor — Lakeside Pediatrics\nAfter hours: nurse line (555) 201-4499', pinned: true });
  await create('infoCards', owner, { family: fam.id, title: 'Bedtime routine', kind: 'routine', body: '7:00 bath · 7:30 two books · 7:45 lights out (Leo needs the hall light on)', pinned: true, aboutMember: leo });
  await create('infoCards', owner, { family: fam.id, title: 'Wi-Fi', kind: 'home', body: 'Network: Riverhouse\nPassword: on the fridge' });
  log('seeded events, to-dos and care info');

  // ---------------------------------------------------------------- groceries through the UI
  await page.reload();
  await page.getByRole('link', { name: 'Groceries' }).first().click();
  const add = page.getByLabel('Add grocery items');
  await add.fill('2 lbs chicken breast, milk x2, bananas, baby spinach, frozen peas, cheerios, paper towels, dog food, greek yogurt, sourdough bread, AA batteries, kombucha, 3 avocados, half and half, gochujang');
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  for (const aisle of ['Produce', 'Meat & Seafood', 'Dairy & Eggs', 'Frozen', 'Breakfast & Cereal', 'Household', 'Pets', 'International']) {
    await page.getByRole('heading', { name: new RegExp(aisle.replace('&', '&')) }).first().waitFor({ timeout: 5000 });
  }
  await add.fill('milk');
  await page.keyboard.press('Enter');
  const milkQty = await page.locator('.grow-item', { hasText: 'Milk' }).first().locator('.qty').innerText();
  assert.equal(milkQty, '3', 'adding milk again should merge into the existing line');
  await page.locator('.grow-item', { hasText: 'Bananas' }).locator('.check').click();
  await page.locator('.grow-item', { hasText: 'Cheerios' }).locator('.check').click();
  await shot(page, '05-groceries');
  log('groceries grouped into aisles; duplicates merged');

  // ---------------------------------------------------------------- quick add an event in plain English
  await page.getByRole('link', { name: 'Calendar' }).first().click();
  await page.getByRole('button', { name: 'New' }).click();
  await page.getByRole('menuitem', { name: /Quick add/ }).or(page.locator('.menu-pop button', { hasText: 'Quick add' })).first().click();
  await page.getByLabel('Describe it in plain English').fill('Book club every first tuesday 7pm @Sam remind 1h');
  await page.locator('.chip', { hasText: 'Monthly on the 1st Tue' }).waitFor();
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  log('quick add parsed a monthly ordinal recurrence');

  // Calendar views
  await page.getByRole('tab', { name: 'Month' }).click();
  await page.locator('.pill', { hasText: 'Soccer practice' }).first().waitFor();
  await shot(page, '02-calendar-month');
  await page.getByRole('tab', { name: 'Week' }).click();
  await page.locator('.ev', { hasText: 'Soccer practice' }).first().waitFor();
  await shot(page, '03-calendar-week');
  await page.getByRole('tab', { name: 'People' }).click();
  await shot(page, '04-calendar-people');
  await page.getByRole('tab', { name: 'Year' }).click();
  await shot(page, '04b-calendar-year');
  await page.getByRole('tab', { name: 'Agenda' }).click();
  await page.getByText('Book club').first().waitFor();

  // Event detail
  await page.getByText('Soccer practice').first().click();
  await page.getByText('Weekly on Tue, Thu').waitFor();
  await page.getByText('Sam is driving').waitFor();
  await shot(page, '06-event-detail');
  await page.keyboard.press('Escape');

  // Today and to-dos
  await page.getByRole('link', { name: 'Today' }).first().click();
  await page.getByText('Dinner with the Parks').first().waitFor();
  await shot(page, '00-today');
  await page.getByRole('link', { name: 'To-Dos' }).first().click();
  await page.getByText('Sign Emma’s field trip permission slip').waitFor();
  await shot(page, '07-todos');
  await page.getByRole('link', { name: 'Family' }).first().click();
  await page.getByText('Bedtime routine').waitFor();
  await page.getByRole('link', { name: /People & roles/ }).click();
  await page.getByText('Pending invites').waitFor();
  await shot(page, '08-family-people');

  // Edit sharing UI exists for admins
  await page.getByRole('link', { name: /Calendars/ }).click();
  await page.getByText('See Roost in your other calendars').waitFor();
  await shot(page, '09-family-calendars');

  // ---------------------------------------------------------------- nanny joins with the invite code
  const nctx = await browser.newContext(phone);
  const np = await nctx.newPage();
  np.on('pageerror', (e) => consoleErrors.push('nanny: ' + e.message));
  await np.goto(APP + '?code=' + nannyCode);
  await np.getByText('Join The Riveras').waitFor();
  await np.getByLabel('Your name').fill('Maria');
  await np.getByLabel('Email').fill('maria@example.com');
  await np.getByLabel('Choose a password (8+)').fill(PW);
  await shot(np, '10-phone-join');
  await np.getByRole('button', { name: 'Join family' }).click();
  await np.getByRole('heading', { name: /Good (morning|afternoon|evening), Maria/ }).waitFor();
  log('nanny joined with the invite code');

  // Assign the nanny a task from the parents' private To-Do list.
  const maria = (await list('memberships', owner, "name = 'Maria'"))[0].id;
  await api(`/api/collections/tasks/records/${pickup.id}`, { token: owner, method: 'PATCH', body: { assignees: [maria] } });
  await np.reload();
  await shot(np, '11-phone-today-nanny');

  // Nanny's access: groceries yes, parents' to-do list no, assigned task yes, Alex's clinic as Busy.
  await np.getByRole('link', { name: 'To-Dos' }).click();
  await np.getByRole('button', { name: /Assigned to me/ }).click();
  await np.getByText('Pick up Leo’s prescription').waitFor();
  assert.equal(await np.getByText('Renew passports').count(), 0, 'nanny must not see the parents’ private to-dos');
  await np.getByRole('link', { name: 'Calendar' }).click();
  await np.getByLabel('Calendar view').selectOption('agenda');
  await np.getByText('Alex Rivera busy').first().waitFor();
  assert.equal(await np.getByText('Dermatology board review').count(), 0, 'personal details must not leak to the nanny');
  await shot(np, '12-phone-calendar-nanny');
  await np.getByRole('link', { name: 'Groceries' }).click();
  await np.locator('.grow-item', { hasText: 'Chicken breast' }).waitFor();
  await shot(np, '13-phone-groceries');
  log('nanny sees groceries + assigned task, parents’ calendar only as busy');

  // Grandma: family calendar read-only, no lists.
  const gctx = await browser.newContext(phone);
  const gp = await gctx.newPage();
  await gp.goto(APP);
  await gp.getByRole('button', { name: 'Sign in' }).click();
  await gp.getByLabel('Email').fill('grandma@example.com');
  await gp.getByLabel('Password').fill(PW);
  await gp.getByRole('button', { name: 'Sign in' }).click();
  await gp.getByRole('heading', { name: /Grandma/ }).waitFor();
  await gp.getByRole('link', { name: 'Calendar' }).click();
  await gp.getByLabel('Calendar view').selectOption('agenda');
  await gp.getByText('Swim lessons').first().waitFor();
  assert.equal(await gp.getByText('Date night').count(), 0, 'private events stay private');
  assert.ok(await gp.getByRole('button', { name: 'New' }).isDisabled(), 'grandma cannot add events');
  await gp.getByRole('link', { name: 'Groceries' }).click();
  await gp.getByText('No grocery list').waitFor();
  log('grandma sees the family calendar read-only and no lists');

  // ---------------------------------------------------------------- realtime: owner adds, nanny sees it without reload
  await np.getByRole('link', { name: 'Groceries' }).click();
  await api('/api/collections/groceryItems/records', { token: sam, method: 'POST', body: { list: grocery.id, name: 'Birthday candles', category: 'baking' } });
  await np.getByText('Birthday candles').waitFor({ timeout: 8000 });
  log('realtime update reached the nanny’s phone');

  // ---------------------------------------------------------------- phone + dark mode screenshots for the owner
  const octx = await browser.newContext({ ...phone, colorScheme: 'dark' });
  const op = await octx.newPage();
  await op.goto(APP);
  await op.getByRole('button', { name: 'Sign in' }).click();
  await op.getByLabel('Email').fill('alex@example.com');
  await op.getByLabel('Password').fill(PW);
  await op.getByRole('button', { name: 'Sign in' }).click();
  await op.getByRole('heading', { name: /Alex/ }).waitFor();
  await shot(op, '14-phone-today-dark');
  await op.getByRole('link', { name: 'Calendar' }).click();
  await op.getByLabel('Calendar view').selectOption('month');
  await shot(op, '15-phone-month-dark');

  assert.deepEqual(consoleErrors, [], 'no uncaught errors in the browser');
  console.log('\nE2E PASSED — screenshots in docs/screenshots/');
} catch (e) {
  console.error('\nE2E FAILED:', e.message);
  process.exitCode = 1;
} finally {
  await browser.close();
}
