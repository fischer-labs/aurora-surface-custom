import { Component, useEffect, useState, type ReactNode } from 'react';
import { BrowserRouter, NavLink, Navigate, Route, Routes } from 'react-router-dom';
import { CalendarDays, ListChecks, ShoppingCart, Sun, Users } from 'lucide-react';
import { bootstrap, dismissRejected, expireSession, todayKey, useRoost } from './data/store';
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
  if (base) return base.replace(/\/$/, '');
  // Built with `vite build --base=/hidden/path/` for hosting on another site.
  const viteBase = import.meta.env.BASE_URL;
  return viteBase.startsWith('/') ? viteBase.replace(/\/$/, '') : '';
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

/** One broken screen shouldn't take the whole app down. */
class Boundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="card stack" style={{ maxWidth: 520 }}>
        <b>Something went wrong showing this screen.</b>
        <span className="muted small">{this.state.error.message}</span>
        <button className="btn" onClick={() => this.setState({ error: null })}>Try again</button>
      </div>
    );
  }
}

function Banners() {
  const s = useRoost();
  if (s.needsSignIn) {
    return (
      <div className="banner">
        <span>Your sign-in expired.{s.outbox.length ? ` ${s.outbox.length} change${s.outbox.length === 1 ? ' is' : 's are'} saved here and will be sent when you sign back in.` : ''}</span>
        <button className="btn sm primary" onClick={expireSession}>Sign in</button>
      </div>
    );
  }
  if (s.rejected.length) {
    return (
      <div className="banner warn">
        <span>The server didn't accept {s.rejected[0].what}: {s.rejected[0].message}{s.rejected.length > 1 ? ` (+${s.rejected.length - 1} more)` : ''}</span>
        <button className="btn sm" onClick={dismissRejected}>OK</button>
      </div>
    );
  }
  return null;
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
        <Banners />
        <Boundary>
        <Routes>
          <Route path="/" element={<Today />} />
          <Route path="/calendar" element={<CalendarPage />} />
          <Route path="/todos" element={<Todos />} />
          <Route path="/todos/:listId" element={<Todos />} />
          <Route path="/groceries" element={<Groceries />} />
          <Route path="/family/*" element={<FamilyPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
        </Boundary>
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
