import { useMemo, useState } from 'react';
import { ArrowDown, ArrowUp, ArrowUpDown, Check, ChevronDown, ChevronRight, Copy, Ellipsis, Plus, RotateCcw, ShoppingBasket, Sparkles, Trash2 } from 'lucide-react';
import {
  addGroceries, canEditList, clearChecked, deleteGrocery, isAdmin, liveLists, me, orderedCategories, saveGrocery, saveList, setGroceryCategory,
  suggestions, toggleGrocery, useRoost,
} from '../data/store';
import type { GroceryRec, ListRec } from '../data/models';
import { categorize, formatQuantity, parseGroceryLine, taxonomy, type GroceryCategory } from '../core/grocery';
import { Empty, Field, Menu, Modal, useToast } from '../ui/kit';
import { ListSettings } from './Todos';
import { learnedMap } from '../data/store';

const KNOWN = new Set(taxonomy.categories.map((c) => c.key));

export function Groceries() {
  const s = useRoost();
  const lists = liveLists(s).filter((l) => l.kind === 'grocery');
  const [selected, setSelected] = useState(() => localStorage.getItem('roost.groceryList') ?? '');
  const list = lists.find((l) => l.id === selected) ?? lists[0];
  const [toast, showToast] = useToast();
  const [aisles, setAisles] = useState(false);
  const [settings, setSettings] = useState(false);

  if (!list) {
    return <div className="page"><div className="pagehead"><h1>Groceries</h1></div>
      <div className="card"><Empty icon={<ShoppingBasket size={28} />} title="No grocery list">Ask a parent to share the family grocery list with you.</Empty></div></div>;
  }
  const pick = (id: string) => { setSelected(id); try { localStorage.setItem('roost.groceryList', id); } catch { /* ignore */ } };
  const copyText = () => {
    const open = s.grocery.filter((g) => g.list === list.id && !g.deleted && !g.checked);
    const lines = [list.name];
    for (const c of orderedCategories(list)) {
      const items = open.filter((g) => g.category === c.key);
      if (!items.length) continue;
      lines.push('', `${c.emoji} ${c.name}`, ...items.map((g) => `☐ ${g.name}${formatQuantity(g.quantity, g.unit) ? ` (${formatQuantity(g.quantity, g.unit)})` : ''}`));
    }
    void navigator.clipboard?.writeText(lines.join('\n')).then(() => showToast('List copied'));
  };

  return (
    <div className="page" style={{ maxWidth: 820 }}>
      <div className="pagehead">
        <h1 className="grow">{list.name}</h1>
        {lists.length > 1 && (
          <select className="input" style={{ width: 'auto' }} value={list.id} onChange={(e) => pick(e.target.value)} aria-label="Grocery list">
            {lists.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
          </select>
        )}
        <Menu trigger={(t) => <button className="btn icon" onClick={t} aria-label="More"><Ellipsis size={18} /></button>}>
          {(close) => (
            <>
              <button onClick={() => { close(); copyText(); }}><Copy size={16} /> Copy list as text</button>
              <button disabled={!canEditList(list, s)} onClick={() => { close(); setAisles(true); }}><ArrowUpDown size={16} /> Store aisle order</button>
              {(isAdmin(s) || list.owner === me(s)?.id) && <button onClick={() => { close(); setSettings(true); }}><Ellipsis size={16} /> List settings & sharing</button>}
            </>
          )}
        </Menu>
      </div>
      <GroceryList list={list} />
      {toast}
      {aisles && <AisleOrder list={list} onClose={() => setAisles(false)} />}
      {settings && <ListSettings list={list} isNew={false} onClose={() => setSettings(false)} />}
    </div>
  );
}

function GroceryList({ list }: { list: ListRec }) {
  const s = useRoost();
  const [text, setText] = useState('');
  const [showCart, setShowCart] = useState(true);
  const [edit, setEdit] = useState<GroceryRec | null>(null);
  const editable = canEditList(list, s);
  const items = s.grocery.filter((g) => g.list === list.id && !g.deleted);
  const open = items.filter((g) => !g.checked);
  const cart = items.filter((g) => g.checked).sort((a, b) => b.checkedAt.localeCompare(a.checkedAt));
  const sugg = suggestions(list.id, 10);
  const preview = useMemo(() => {
    const first = text.split(/[\n,;]/)[0];
    const p = parseGroceryLine(first);
    if (!p) return null;
    const c = taxonomy.category(categorize(p.name, learnedMap(s)).category);
    return `${c.emoji} ${p.name}${formatQuantity(p.quantity, p.unit) ? ` · ${formatQuantity(p.quantity, p.unit)}` : ''} → ${c.name}`;
  }, [text, s]);

  const add = () => { if (text.trim()) { addGroceries(text, list.id); setText(''); } };
  const cats = orderedCategories(list);

  return (
    <>
      {editable && (
        <div style={{ marginBottom: 6 }}>
          <div className="addbar">
            <Plus size={18} color="var(--accent)" />
            <textarea rows={1} value={text} onChange={(e) => setText(e.target.value)} aria-label="Add grocery items"
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); add(); } }}
              onPaste={(e) => { const t = e.clipboardData.getData('text'); if (t.includes('\n')) { e.preventDefault(); addGroceries(t, list.id); } }}
              placeholder="Add items — “2 lb chicken, milk x2, eggs” (paste a whole list!)" />
            <button className="btn primary sm" onClick={add} disabled={!text.trim()}>Add</button>
          </div>
          {preview && <div className="hint">{preview}</div>}
          {!text && sugg.length > 0 && (
            <div className="sugg" aria-label="Buy again">
              {sugg.map((x) => <button key={x} onClick={() => addGroceries(x, list.id)}><RotateCcw size={11} style={{ verticalAlign: -1, marginRight: 4 }} />{x}</button>)}
            </div>
          )}
        </div>
      )}
      {!open.length && !cart.length && <div className="card"><Empty icon={<ShoppingBasket size={28} />} title="List is empty">Type or paste items — they'll sort themselves into aisles.</Empty></div>}
      {cats.map((c) => {
        const inCat = open.filter((g) => g.category === c.key || (c.key === 'other' && !KNOWN.has(g.category))).sort((a, b) => a.sortOrder - b.sortOrder);
        if (!inCat.length) return null;
        return (
          <div key={c.key} className="aisle">
            <h3>{c.emoji} {c.name} <span className="n">{inCat.length}</span></h3>
            <div className="card flush">{inCat.map((g) => <Row key={g.id} g={g} editable={editable} onEdit={() => setEdit(g)} />)}</div>
          </div>
        );
      })}
      {cart.length > 0 && (
        <div className="aisle">
          <h3 style={{ justifyContent: 'space-between' }}>
            <button className="btn ghost sm" onClick={() => setShowCart(!showCart)}>{showCart ? <ChevronDown size={14} /> : <ChevronRight size={14} />} In the cart ({cart.length})</button>
            {editable && <button className="btn ghost sm" onClick={() => clearChecked(list.id)}><Trash2 size={14} /> Clear</button>}
          </h3>
          {showCart && <div className="card flush">{cart.map((g) => <Row key={g.id} g={g} editable={editable} onEdit={() => setEdit(g)} />)}</div>}
        </div>
      )}
      {edit && <ItemEditor item={edit} onClose={() => setEdit(null)} />}
    </>
  );
}

function Row({ g, editable, onEdit }: { g: GroceryRec; editable: boolean; onEdit: () => void }) {
  const q = formatQuantity(g.quantity, g.unit);
  return (
    <div className={`grow-item${g.checked ? ' done' : ''}`}>
      <button className={`check green${g.checked ? ' on' : ''}`} disabled={!editable} onClick={() => toggleGrocery(g)} aria-label={g.checked ? 'Put back' : 'Got it'}>
        {g.checked && <Check size={14} strokeWidth={3} />}
      </button>
      <div className="name" onClick={() => editable && onEdit()} role="button" tabIndex={0}>
        {g.name} {g.categorySource === 'ai' && <Sparkles size={12} color="var(--accent)" aria-label="Sorted by AI" />}
        {g.note && <div className="small muted">{g.note}</div>}
      </div>
      {q && <span className="qty">{q}</span>}
      {editable && (
        <Menu trigger={(t) => <button className="btn ghost icon" onClick={t} aria-label={`Move ${g.name}`}><ArrowUpDown size={15} /></button>}>
          {(close) => (
            <div style={{ maxHeight: 320, overflow: 'auto' }}>
              <div className="label">Move to aisle</div>
              {taxonomy.categories.map((c: GroceryCategory) => (
                <button key={c.key} className={g.category === c.key ? 'on' : ''} onClick={() => { close(); setGroceryCategory(g, c.key); }}>{c.emoji} {c.name}</button>
              ))}
              <hr />
              <button onClick={() => { close(); deleteGrocery(g); }}><Trash2 size={15} /> Delete</button>
            </div>
          )}
        </Menu>
      )}
    </div>
  );
}

function ItemEditor({ item, onClose }: { item: GroceryRec; onClose: () => void }) {
  const [g, setG] = useState(item);
  const [qty, setQty] = useState(item.quantity ? String(item.quantity) : '');
  const save = () => {
    const out = { ...g, quantity: Number(qty.replace(',', '.')) > 0 ? Number(qty.replace(',', '.')) : 0 };
    if (out.category !== item.category) { setGroceryCategory(item, out.category); saveGrocery({ ...out, categorySource: 'manual' }); } else saveGrocery(out);
    onClose();
  };
  return (
    <Modal title="Edit item" onClose={onClose} actions={<button className="btn primary sm" onClick={save} disabled={!g.name.trim()}>Save</button>}>
      <input className="input big" value={g.name} onChange={(e) => setG({ ...g, name: e.target.value })} />
      <div className="row">
        <Field label="Qty"><input className="input" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} style={{ width: 90 }} /></Field>
        <Field label="Unit"><input className="input" value={g.unit} placeholder="lb, oz, pack…" onChange={(e) => setG({ ...g, unit: e.target.value })} /></Field>
      </div>
      <input className="input" placeholder="Note (brand, size…)" value={g.note} onChange={(e) => setG({ ...g, note: e.target.value })} />
      <Field label="Aisle">
        <select className="input" value={g.category} onChange={(e) => setG({ ...g, category: e.target.value })}>
          {taxonomy.categories.map((c) => <option key={c.key} value={c.key}>{c.emoji} {c.name}</option>)}
        </select>
      </Field>
      <div className="faint small">Changing the aisle teaches Roost for next time — for everyone in the family.</div>
      <button className="btn danger" onClick={() => { deleteGrocery(item); onClose(); }}><Trash2 size={16} /> Delete</button>
    </Modal>
  );
}

function AisleOrder({ list, onClose }: { list: ListRec; onClose: () => void }) {
  const [order, setOrder] = useState(orderedCategories(list));
  const move = (i: number, d: number) => {
    const j = i + d;
    if (j < 0 || j >= order.length) return;
    const next = [...order];
    [next[i], next[j]] = [next[j], next[i]];
    setOrder(next);
  };
  return (
    <Modal title="Aisle order" onClose={onClose}
      actions={<button className="btn primary sm" onClick={() => { saveList({ ...list, storeOrder: order.map((c) => c.key) }); onClose(); }}>Save</button>}>
      <div className="faint small">Put aisles in the order you walk your store. Tip: make one grocery list per store (Costco, Trader Joe's) — each keeps its own order.</div>
      <div className="card flush">
        {order.map((c, i) => (
          <div key={c.key} className="order-row">
            <span style={{ flex: 1 }}>{c.emoji} {c.name}</span>
            <button className="btn ghost icon" onClick={() => move(i, -1)} disabled={i === 0} aria-label={`Move ${c.name} up`}><ArrowUp size={15} /></button>
            <button className="btn ghost icon" onClick={() => move(i, 1)} disabled={i === order.length - 1} aria-label={`Move ${c.name} down`}><ArrowDown size={15} /></button>
          </div>
        ))}
      </div>
      <button className="btn ghost" onClick={() => setOrder(taxonomy.categories)}>Reset to default</button>
    </Modal>
  );
}
