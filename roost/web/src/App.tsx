import { useEffect, useState } from 'react';
import { BrowserRouter, NavLink, Navigate, Route, Routes } from 'react-router-dom';
import { CalendarDays, ListChecks, ShoppingCart, Sun, Users } from 'lucide-react';
import { bootstrap, todayKey, useRoost } from './data/store';
import { Logo, SyncBadge } from './ui/kit';
import { Onboarding } from './views/Onboarding';
import { Today } from './views/Today';
import { CalendarPage } from './views/Calendar';
import { Todos } from './views/Todos';
import { Groceries } from './views/Groceries';
import { FamilyPage } from './views/Family';

/** Router basename = the unlisted path the server injected via <base href>. */
function basename(): string {
  const fromConfig = window.ROOST_CONFIG?.basePath;
  if (fromConfig) return fromConfig.replace(/\/$/, '');
  const base = document.querySelector('base')?.getAttribute('href');
  return base ? base.replace(/\/$/, '') : '';
}

const NAV = [
  { to: '/', label: 'Today', icon: Sun, end: true },
  { to: '/calendar', label: 'Calendar', icon: CalendarDays },
  { to: '/todos', label: 'To-Dos', icon: ListChecks },
  { to: '/groceries', label: 'Groceries', icon: ShoppingCart },
  { to: '/family', label: 'Family', icon: Users },
];

export function App() {
  const s = useRoost();
  useEffect(() => { void bootstrap(); }, []);
  useEffect(() => {
    if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js').catch(() => undefined);
  }, []);

  if (s.phase === 'loading') {
    return <div className="welcome"><div className="box" style={{ alignItems: 'center' }}><Logo size={84} /></div></div>;
  }
  return (
    <BrowserRouter basename={basename()}>
      {s.phase === 'onboarding' ? <Onboarding /> : <Shell />}
    </BrowserRouter>
  );
}

function Shell() {
  const s = useRoost();
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 60_000); return () => clearInterval(t); }, []);
  const today = todayKey();
  const counts: Record<string, number> = {
    '/todos': s.tasks.filter((t) => !t.deleted && !t.completed && t.due && t.due.slice(0, 10) <= today).length,
    '/groceries': s.grocery.filter((g) => !g.deleted && !g.checked).length,
  };
  return (
    <div className="shell">
      <nav className="sidebar" aria-label="Main">
        <div className="brand">
          <Logo size={36} />
          <div><b>Roost</b><small>{s.family?.name}</small></div>
        </div>
        {NAV.map(({ to, label, icon: Icon, end }) => (
          <NavLink key={to} to={to} end={end} className={({ isActive }) => `navlink${isActive ? ' active' : ''}`}>
            <Icon size={19} /> {label}
            {counts[to] ? <span className="count">{counts[to]}</span> : null}
          </NavLink>
        ))}
        <div className="spacer" />
        <div style={{ padding: '0 12px' }}><SyncBadge /></div>
      </nav>
      <main className="main">
        <Routes>
          <Route path="/" element={<Today />} />
          <Route path="/calendar" element={<CalendarPage />} />
          <Route path="/todos" element={<Todos />} />
          <Route path="/todos/:listId" element={<Todos />} />
          <Route path="/groceries" element={<Groceries />} />
          <Route path="/family/*" element={<FamilyPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
      <nav className="tabbar" aria-label="Tabs">
        {NAV.map(({ to, label, icon: Icon, end }) => (
          <NavLink key={to} to={to} end={end} className={({ isActive }) => (isActive ? 'active' : '')}>
            <Icon size={22} />{label}
          </NavLink>
        ))}
      </nav>
    </div>
  );
}
