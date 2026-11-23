import { useEffect, useState, type FormEvent } from 'react';
import { ChevronRight, House, MailOpen, UserRound } from 'lucide-react';
import { createAccount, createFamily, invitePreview, joinFamily, pb, signIn } from '../data/store';
import { ROLE_BLURB, ROLE_LABEL, type Role } from '../core/logic';
import { localTZ } from '../core/localdate';
import { errorText, Field, Logo } from '../ui/kit';

type Step = 'welcome' | 'create' | 'join' | 'signin';

export function Onboarding() {
  const params = new URLSearchParams(location.search);
  const [step, setStep] = useState<Step>(params.get('code') ? 'join' : 'welcome');
  return (
    <div className="welcome">
      <div className="box">
        <Logo size={88} />
        {step === 'welcome' && (
          <>
            <h1>Roost</h1>
            <p className="lede">Your family's calendar, lists and groceries — shared with exactly the right people.</p>
            <button className="bigbtn primary" onClick={() => setStep('create')}><House size={20} /><span>Start a new family</span><ChevronRight size={18} /></button>
            <button className="bigbtn" onClick={() => setStep('join')}><MailOpen size={20} /><span>I have an invite code</span><ChevronRight size={18} /></button>
            <button className="bigbtn" onClick={() => setStep('signin')}><UserRound size={20} /><span>Sign in</span><ChevronRight size={18} /></button>
          </>
        )}
        {step === 'create' && <CreateFamily back={() => setStep('welcome')} />}
        {step === 'join' && <Join back={() => setStep('welcome')} initialCode={params.get('code') ?? ''} />}
        {step === 'signin' && <SignIn back={() => setStep('welcome')} />}
      </div>
    </div>
  );
}

function Back({ onClick }: { onClick: () => void }) {
  return <button type="button" className="btn ghost sm" onClick={onClick} style={{ alignSelf: 'flex-start' }}>← Back</button>;
}

function CreateFamily({ back }: { back: () => void }) {
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [family, setFamily] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [accountDone, setAccountDone] = useState(false);
  const [needsSetup, setNeedsSetup] = useState(false);
  const [setupCode, setSetupCode] = useState('');
  useEffect(() => {
    pb.send<{ setupCode?: boolean }>('/api/roost/config', {}).then((c) => setNeedsSetup(!!c.setupCode)).catch(() => undefined);
  }, []);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      if (!accountDone) { await createAccount(name, email, password, needsSetup ? setupCode.trim() : undefined); setAccountDone(true); }
      await createFamily(family, localTZ());
    } catch (err) { setError(errorText(err)); } finally { setBusy(false); }
  }
  return (
    <form className="card stack" onSubmit={submit}>
      <Back onClick={back} />
      <h2>Start a new family</h2>
      {!accountDone && (
        <>
          <Field label="Your name"><input className="input" required value={name} onChange={(e) => setName(e.target.value)} autoComplete="given-name" /></Field>
          <Field label="Email"><input className="input" required type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" /></Field>
          <Field label="Password (8+ characters)"><input className="input" required minLength={8} type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" /></Field>
          {needsSetup && (
            <Field label="Setup code">
              <input className="input" required placeholder="XXXX-XXXX" value={setupCode} onChange={(e) => setSetupCode(e.target.value)} autoComplete="off" autoCapitalize="characters" />
              <span className="faint small">The first account on a new server needs the code printed in the Roost server log (for example <code>docker compose logs roost</code>).</span>
            </Field>
          )}
        </>
      )}
      <Field label="Family name"><input className="input" required placeholder="e.g. The Riveras" value={family} onChange={(e) => setFamily(e.target.value)} /></Field>
      <p className="faint small" style={{ margin: 0 }}>You'll be the owner. Invite your partner, nanny and grandparents next — each gets their own level of access. Time zone: {localTZ()}.</p>
      {error && <div className="err">{error}</div>}
      <button className="btn primary block" disabled={busy}>{busy ? 'Creating…' : 'Create family'}</button>
    </form>
  );
}

function Join({ back, initialCode }: { back: () => void; initialCode: string }) {
  const [code, setCode] = useState(initialCode);
  const [preview, setPreview] = useState<{ family: string; role: Role; name: string } | null>(null);
  const [haveAccount, setHaveAccount] = useState(false);
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function lookUp() {
    setError(null);
    try {
      const p = await invitePreview(code.trim());
      setPreview(p);
      if (!name) setName(p.name);
    } catch (err) { setError(errorText(err)); setPreview(null); }
  }
  useEffect(() => { if (initialCode) void lookUp(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      if (haveAccount) await signInOnly(email, password);
      else await createAccount(name, email, password, code.trim());
      await joinFamily(code.trim(), haveAccount ? undefined : name);
    } catch (err) { setError(errorText(err)); } finally { setBusy(false); }
  }
  return (
    <form className="card stack" onSubmit={submit}>
      <Back onClick={back} />
      <h2>Join a family</h2>
      <Field label="Invite code">
        <div className="row">
          <input className="input" style={{ fontFamily: 'var(--mono)', fontSize: 20, letterSpacing: '.08em', textTransform: 'uppercase' }}
            placeholder="K7QM-2XPD" value={code} onChange={(e) => { setCode(e.target.value); setPreview(null); }} />
          <button type="button" className="btn" onClick={lookUp} disabled={code.replace(/\W/g, '').length < 8}>Look up</button>
        </div>
      </Field>
      {preview && (
        <>
          <div className="card" style={{ background: 'var(--accent-soft)', borderColor: 'transparent', boxShadow: 'none' }}>
            <b>Join {preview.family}</b> as <b>{ROLE_LABEL[preview.role]}</b>
            <div className="small muted">{ROLE_BLURB[preview.role]}</div>
          </div>
          <label className="toggle"><span>I already have a Roost account</span><input type="checkbox" role="switch" checked={haveAccount} onChange={(e) => setHaveAccount(e.target.checked)} /></label>
          {!haveAccount && <Field label="Your name"><input className="input" required value={name} onChange={(e) => setName(e.target.value)} /></Field>}
          <Field label="Email"><input className="input" required type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" /></Field>
          <Field label={haveAccount ? 'Password' : 'Choose a password (8+)'}>
            <input className="input" required minLength={8} type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete={haveAccount ? 'current-password' : 'new-password'} />
          </Field>
          <button className="btn primary block" disabled={busy}>{busy ? 'Joining…' : 'Join family'}</button>
        </>
      )}
      {error && <div className="err">{error}</div>}
    </form>
  );
}

async function signInOnly(email: string, password: string) {
  await pb.collection('users').authWithPassword(email, password);
}

function SignIn({ back }: { back: () => void }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    try { await signIn(email, password); } catch (err) { setError(errorText(err)); } finally { setBusy(false); }
  }
  return (
    <form className="card stack" onSubmit={submit}>
      <Back onClick={back} />
      <h2>Sign in</h2>
      <Field label="Email"><input className="input" required type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" /></Field>
      <Field label="Password"><input className="input" required type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="current-password" /></Field>
      {error && <div className="err">{error}</div>}
      <button className="btn primary block" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
    </form>
  );
}
