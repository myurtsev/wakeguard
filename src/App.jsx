import { useEffect, useRef, useState } from 'react'

const ICON = `${import.meta.env.BASE_URL}wakeguard-icon.png`
const SOURCE_URL = 'https://github.com/myurtsev/wakeguard'
const RELEASE = 'v1.3.4-beta.1'
const DOWNLOAD_URL = `${SOURCE_URL}/releases/download/${RELEASE}/WakeGuard.dmg`
const RELEASE_URL = `${SOURCE_URL}/releases/tag/${RELEASE}`
const BLUE = '#4d8dff', AMBER = '#f2b84b', GREEN = '#8fd19e', GREY = '#5c626d'

const PHASES = [
  { tab: 'Working', bar: BLUE, codex: [BLUE, '2 working'], claude: [BLUE, '1 working'], title: 'Mac stays awake', text: 'Sleep is prevented while any supported task is working.' },
  { tab: 'Waiting for input', bar: AMBER, codex: [BLUE, '1 working'], claude: [AMBER, '1 waiting'], title: 'Still awake', text: 'Tasks waiting for input remain active, so your Mac is ready when you respond.' },
  { tab: 'Finished', bar: GREEN, codex: [GREY, '0 working'], claude: [GREY, '0 working'], title: 'Sleep released', text: 'WakeGuard steps aside. With the lid closed, it requests system sleep.' },
]

const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches

// Flips `.in` once the element scrolls into view; CSS does the choreography.
function Reveal({ as: Tag = 'div', delay = 0, className = '', style, ref: outerRef, ...rest }) {
  const ref = useRef(null)
  const [inView, setInView] = useState(false)
  useEffect(() => {
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) { setInView(true); io.disconnect() }
    }, { rootMargin: '0px 0px -10% 0px' })
    io.observe(ref.current)
    return () => io.disconnect()
  }, [])
  const setRef = el => { ref.current = el; if (outerRef) outerRef.current = el }
  return <Tag ref={setRef} className={`reveal ${inView ? 'in' : ''} ${className}`} style={{ ...style, '--d': `${delay}ms` }} {...rest} />
}

// Splits text into words that rise in one after another inside a <Reveal className="words">.
const Words = ({ children, from = 0 }) => children.split(' ').map((w, i) => (
  <span key={i}><span className="w" style={{ '--i': i + from }}>{w}</span>{' '}</span>
))

// Writes a 0..1 scroll progress to `--p` on the element every frame, without re-rendering.
function useScrollVar(measure) {
  const ref = useRef(null)
  useEffect(() => {
    if (reducedMotion()) return
    let frame
    const update = () => {
      const p = measure(ref.current.getBoundingClientRect(), innerHeight)
      ref.current.style.setProperty('--p', Math.min(1, Math.max(0, p)).toFixed(4))
    }
    const onScroll = () => { cancelAnimationFrame(frame); frame = requestAnimationFrame(update) }
    update()
    addEventListener('scroll', onScroll, { passive: true })
    addEventListener('resize', onScroll)
    return () => { removeEventListener('scroll', onScroll); removeEventListener('resize', onScroll); cancelAnimationFrame(frame) }
  }, [])
  return ref
}

const Dot = ({ color, size = 8, className = '' }) => (
  <span className={`dot ${className}`} style={{ width: size, height: size, background: color }} />
)

const Check = () => (
  <span className="check"><svg width="10" height="10" viewBox="0 0 10 10"><polyline points="2,5.2 4.2,7.4 8,2.8" fill="none" stroke="#fff" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" /></svg></span>
)

const SunRays = ({ stroke, width, diagonals }) => (
  <g stroke={stroke} strokeWidth={width} strokeLinecap="round">
    <line x1="8" y1="1" x2="8" y2="2.6" /><line x1="8" y1="13.4" x2="8" y2="15" />
    <line x1="1" y1="8" x2="2.6" y2="8" /><line x1="13.4" y1="8" x2="15" y2="8" />
    {diagonals && <><line x1="3" y1="3" x2="4.1" y2="4.1" /><line x1="11.9" y1="11.9" x2="13" y2="13" /><line x1="3" y1="13" x2="4.1" y2="11.9" /><line x1="11.9" y1="4.1" x2="13" y2="3" /></>}
  </g>
)

// Hero demo loop: 0 lid open → 1–3 lid closed, agents working → 4 an agent waits for input.
const DEMO_STEPS = [4200, 4200, 3600, 3600, 4400]
const DEMO_TIMES = ['22:14', '22:16', '22:31', '22:46', '22:51']

function useDemo() {
  const [step, setStep] = useState(0)
  const [run, setRun] = useState(0)
  useEffect(() => {
    if (reducedMotion()) { setStep(2); return }
    let t
    const tick = s => { t = setTimeout(() => { const n = (s + 1) % DEMO_STEPS.length; setStep(n); tick(n) }, DEMO_STEPS[s]) }
    setStep(0)
    tick(0)
    return () => clearTimeout(t)
  }, [run])
  return [step, () => setRun(r => r + 1)]
}

function LidStage({ step }) {
  const open = step === 0
  return (
    <div className="lid-stage" aria-hidden="true">
      <div className="lid-shadow" />
      <div className="lid-hinge">
        <div className="lid-base">
          <div style={{ position: 'absolute', left: 20, right: 20, top: 18, height: 82, borderRadius: 7, background: '#3a3f47', opacity: 0.85 }} />
          <div style={{ position: 'absolute', left: 110, right: 110, top: 114, height: 64, borderRadius: 7, background: '#d7dbe1', boxShadow: 'inset 0 0 0 1px rgba(20,22,26,.08)' }} />
        </div>
        <div className="lid" style={{ transform: open ? 'rotateX(12deg)' : 'rotateX(-104deg)' }}>
          <div className="lid-screen" style={{ opacity: open ? 1 : 0, transitionDelay: open ? '1.6s' : '1s' }}>
            <div style={{ left: 8, right: 8, top: 8, height: 5, background: 'rgba(255,255,255,.12)' }} />
            <div style={{ left: 10, top: 34, width: '58%', background: '#4d8dff', opacity: 0.8 }} />
            <div style={{ left: 10, top: 50, width: '44%', background: 'rgba(255,255,255,.28)' }} />
            <div style={{ left: 10, top: 66, width: '66%', background: 'rgba(255,255,255,.28)' }} />
            <div style={{ left: 10, top: 82, width: '36%', background: '#8fd19e', opacity: 0.8 }} />
          </div>
          <div className="lid-back" />
        </div>
      </div>
    </div>
  )
}

function Panel({ step, awake, setAwake, agents, setAgents }) {
  const [settings, setSettings] = useState(false)
  const gray = '#5c5c62'
  const codex = !awake ? [gray, '0 working'] : step === 4 ? [AMBER, '1 waiting'] : [BLUE, '2 working']
  const claude = !awake ? [gray, '0 working'] : step < 3 ? [BLUE, '1 working'] : [AMBER, '1 waiting']

  return (
    <div role="group" aria-label="WakeGuard menu bar panel preview" className="panel" style={{ flex: '1 1 260px', maxWidth: 300, margin: 0 }}>
      <div className="row" style={{ gap: 12 }}>
        <img src={ICON} alt="" width="30" height="30" style={{ borderRadius: 8, display: 'block' }} />
        <span style={{ fontWeight: 700, fontSize: 15, flex: 1 }}>WakeGuard</span>
        <span aria-hidden="true" className="row" style={{ gap: 4, color: '#c9c9ce' }}>
          <svg width="18" height="18" viewBox="0 0 18 18"><circle cx="9" cy="9" r="7.5" fill="none" stroke="currentColor" strokeWidth="1.3" /><circle cx="5.6" cy="9" r="1.1" fill="currentColor" /><circle cx="9" cy="9" r="1.1" fill="currentColor" /><circle cx="12.4" cy="9" r="1.1" fill="currentColor" /></svg>
          <svg width="10" height="10" viewBox="0 0 10 10"><polyline points="2,3.5 5,6.5 8,3.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /></svg>
        </span>
      </div>

      <div className="row" style={{ marginTop: 16, gap: 9 }}>
        {awake
          ? <svg aria-hidden="true" width="20" height="20" viewBox="0 0 16 16"><circle cx="8" cy="8" r="3.2" fill="#ffd60a" /><SunRays stroke="#ffd60a" width="1.5" diagonals /></svg>
          : <svg aria-hidden="true" width="20" height="20" viewBox="0 0 16 16"><circle cx="8" cy="8" r="5.6" fill="none" stroke="#c9c9ce" strokeWidth="1.4" /><line x1="5.4" y1="8" x2="10.6" y2="8" stroke="#c9c9ce" strokeWidth="1.4" strokeLinecap="round" /></svg>}
        <span style={{ fontSize: 20, fontWeight: 700 }}>{awake ? 'Awake' : 'Off'}</span>
      </div>
      <div className="sub" style={{ marginTop: 6 }}>
        {!awake ? 'Your Mac can sleep normally.' : agents ? 'Keeping your Mac awake until agents finish.' : 'Keeping your Mac awake until you stop.'}
      </div>
      <button type="button" className={`panel-btn${awake ? '' : ' start'}`} onClick={() => setAwake(!awake)}>{awake ? 'Stop' : 'Start'}</button>

      <div role="radiogroup" aria-label="Mode" className="seg">
        <button type="button" role="radio" aria-checked={!agents} onClick={() => setAgents(false)}>Manual</button>
        <button type="button" role="radio" aria-checked={agents} onClick={() => setAgents(true)} className="agents">Until agents finish</button>
      </div>

      <div className="hr" />
      <div style={{ fontWeight: 700, marginBottom: 8 }}>Agents</div>
      <div className="stack" style={{ gap: 7 }}>
        <div className="between"><span>Codex</span><span className="row" style={{ gap: 7, color: '#b4b4ba' }}><Dot size={7} color={codex[0]} className="pulse" />{codex[1]}</span></div>
        <div className="between"><span>Claude Code</span><span className="row" style={{ gap: 7, color: '#b4b4ba' }}><Dot size={7} color={claude[0]} />{claude[1]}</span></div>
      </div>

      <div className="hr" />
      <div className="stack" style={{ gap: 8, fontSize: 13.5 }}>
        <div className="row" style={{ gap: 9 }}><svg aria-hidden="true" width="14" height="14" viewBox="0 0 16 16"><polygon points="9,1 3,9 7.5,9 6.5,15 13,6.5 8.5,6.5" fill="none" stroke="#98989e" strokeWidth="1.2" strokeLinejoin="round" /></svg><span style={{ color: '#a5a5ab', flex: 1 }}>Power</span><span>AC power · 82%</span></div>
        <div className="row" style={{ gap: 9 }}><svg aria-hidden="true" width="14" height="14" viewBox="0 0 16 16"><rect x="6" y="1.5" width="4" height="9" rx="2" fill="none" stroke="#98989e" strokeWidth="1.2" /><circle cx="8" cy="12.3" r="2.4" fill="none" stroke="#98989e" strokeWidth="1.2" /></svg><span style={{ color: '#a5a5ab', flex: 1 }}>Thermal status</span><span>Normal</span></div>
        <div className="row" style={{ gap: 9 }}><svg aria-hidden="true" width="14" height="14" viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.3" fill="none" stroke="#98989e" strokeWidth="1.2" /><polyline points="8,4.5 8,8 10.5,9.5" fill="none" stroke="#98989e" strokeWidth="1.2" strokeLinecap="round" /></svg><span style={{ color: '#a5a5ab', flex: 1 }}>Time limit</span><span>1 h 14 min left</span></div>
      </div>

      <button type="button" aria-expanded={settings} onClick={() => setSettings(!settings)} className="row" style={{ marginTop: 14, gap: 6, border: 0, background: 'transparent', color: '#f2f2f4', padding: '2px 0', cursor: 'pointer', fontSize: 14 }}>
        <svg aria-hidden="true" width="10" height="10" viewBox="0 0 10 10" style={{ transform: settings ? 'rotate(90deg)' : 'none', transition: 'transform .2s' }}><polyline points="3.5,2 6.5,5 3.5,8" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /></svg>
        Settings
      </button>
      <div className={`collapse${settings ? ' open' : ''}`} inert={!settings}><div>
        <div className="stack" style={{ padding: '10px 0 2px 16px', gap: 10, fontSize: 13.5 }}>
          <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            <span className="row" style={{ gap: 7 }}><Check />AC power</span>
            <span className="row" style={{ gap: 7 }}><span className="check" style={{ background: '#48484c' }} />Battery</span>
          </div>
          <div className="row" style={{ gap: 8 }}>Battery limit <span className="select">20% ⌄</span></div>
          <div className="row" style={{ gap: 8 }}>Time limit <span className="select">2 hours ⌄</span></div>
        </div>
      </div></div>
      <div className="hr" style={{ margin: '12px 0 10px' }} />
      <div style={{ color: '#98989e', fontSize: 13.5 }}>Activity…</div>
    </div>
  )
}

function Agents() {
  const [phase, setPhase] = useState(0)
  const [paused, setPaused] = useState(false)

  useEffect(() => {
    if (paused || matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const t = setInterval(() => setPhase(p => (p + 1) % 3), 3600)
    return () => clearInterval(t)
  }, [paused])

  return (
    <section id="agents" aria-labelledby="agents-title" className="dark" style={{ scrollMarginTop: 60 }}>
      <div className="wrap" style={{ paddingTop: 'clamp(72px,10vw,136px)', paddingBottom: 'clamp(72px,10vw,136px)' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,380px),1fr))', gap: '24px 64px', alignItems: 'end' }}>
          <div className="stack" style={{ gap: 18 }}>
            <Reveal as="span" className="eyebrow">Until agents finish</Reveal>
            <Reveal as="h2" id="agents-title" className="h2 words" style={{ fontSize: 'clamp(34px,4.6vw,54px)', lineHeight: 1.05 }}><Words>Awake while they work. Asleep when they’re done.</Words></Reveal>
          </div>
          <Reveal as="p" delay={200} style={{ margin: 0, fontSize: 18, lineHeight: 1.55, color: '#b3b8c2', textWrap: 'pretty' }}>WakeGuard follows supported local Codex and Claude Code sessions. When every task has finished, it releases sleep prevention — and if the lid is closed, it requests system sleep.</Reveal>
        </div>

        <Reveal role="tablist" aria-label="Agent states" style={{ marginTop: 'clamp(40px,6vw,64px)', display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 8 }}>
          {PHASES.map((p, i) => (
            <button key={i} type="button" role="tab" aria-selected={i === phase} className="tab" onClick={() => { setPaused(true); setPhase(i) }}>
              <span className="tab-bar"><span key={phase} className={`tab-fill${i < phase || (i === phase && paused) ? ' full' : i === phase ? ' run' : ''}`} style={{ background: p.bar }} /></span>
              {i + 1} · {p.tab}
            </button>
          ))}
        </Reveal>

        <div className="grid3" style={{ marginTop: 20 }}>
          {PHASES.map((p, i) => (
            <Reveal key={i} delay={i * 110} className={`phase${i === phase ? ' on' : ''}`}>
              <div style={{ fontWeight: 700, fontSize: 15 }}>Agents</div>
              <div className="stack" style={{ gap: 10, fontSize: 15 }}>
                {[['Codex', p.codex], ['Claude Code', p.claude]].map(([name, [color, label]]) => (
                  <div key={name} className="between"><span>{name}</span><span className="row" style={{ gap: 8, color: '#c2c7d0' }}><Dot color={color} />{label}</span></div>
                ))}
              </div>
              <div style={{ height: 1, background: 'rgba(255,255,255,.08)' }} />
              <div className="stack" style={{ gap: 6 }}>
                <span style={{ fontSize: 17, fontWeight: 650 }}>{p.title}</span>
                <span style={{ fontSize: 14.5, lineHeight: 1.5, color: '#a9aeb8' }}>{p.text}</span>
              </div>
            </Reveal>
          ))}
        </div>

      </div>
    </section>
  )
}

// "In your bag" illustration, drawn with CSS shapes (percentages of a square stage).
// Backdrop layers drift on scroll for depth; the figure stays put.
const BAG_BACKDROP = [
  { inset: 0, background: 'radial-gradient(circle at 50% 34%,#f6f8fc 0%,rgba(246,248,252,0) 46%)' },
  { left: '2%', bottom: '14%', width: '9%', height: '20%', background: '#cad7eb', borderRadius: '3px 3px 0 0' },
  { left: '11.5%', bottom: '14%', width: '6%', height: '30%', background: '#c2d0e7', borderRadius: '3px 3px 0 0' },
  { left: '18%', bottom: '14%', width: '8%', height: '15%', background: '#cad7eb', borderRadius: '3px 3px 0 0' },
  { right: '3%', bottom: '14%', width: '7%', height: '26%', background: '#c2d0e7', borderRadius: '3px 3px 0 0' },
  { right: '10.5%', bottom: '14%', width: '9%', height: '17%', background: '#cad7eb', borderRadius: '3px 3px 0 0' },
  { left: 0, right: 0, bottom: 0, height: '14%', background: 'linear-gradient(180deg,#c4d2e8,#b9c9e2)' },
]
const BAG_FIGURE = [
  { left: '41%', top: '9%', width: '18%', height: '20%', borderRadius: '50% 50% 46% 46% / 56% 56% 44% 44%', background: 'radial-gradient(circle at 42% 30%,#4c525c 0%,#2a2e35 62%,#22252b 100%)' },
  { left: '39.4%', top: '17.6%', width: '3.2%', height: '4.8%', borderRadius: '50%', background: 'linear-gradient(90deg,#d29d7b,#e3b393)' },
  { left: '57.4%', top: '17.6%', width: '3.2%', height: '4.8%', borderRadius: '50%', background: 'linear-gradient(90deg,#e3b393,#d29d7b)' },
  { left: '46%', top: '25.5%', width: '8%', height: '7%', background: 'linear-gradient(180deg,#b9876a 0%,#d6a383 45%,#dcab8b 100%)' },
  { left: '15%', top: '42%', width: '13.5%', height: '62%', borderRadius: '50% 50% 0 0 / 18% 18% 0 0', background: 'linear-gradient(90deg,#4a5a72,#55667f)' },
  { left: '71.5%', top: '42%', width: '13.5%', height: '62%', borderRadius: '50% 50% 0 0 / 18% 18% 0 0', background: 'linear-gradient(90deg,#55667f,#4a5a72)' },
  { left: '18%', top: '32.5%', width: '64%', height: '72%', borderRadius: '36% 36% 0 0 / 16% 16% 0 0', background: 'linear-gradient(90deg,#536580 0%,#647792 50%,#536580 100%)' },
  { left: '36%', top: '29%', width: '28%', height: '8.5%', borderRadius: '50% / 60%', background: 'linear-gradient(180deg,#5d6f8a,#4b5c75)' },
  { left: '41%', top: '30.2%', width: '18%', height: '4%', borderRadius: '50%', background: '#3f4f66' },
  { left: '35.5%', top: '25.5%', width: '29%', height: '16%', borderRadius: '5px 5px 0 0', background: 'linear-gradient(180deg,#f3f5f8 0%,#d9dde3 55%,#c2c8d1 100%)', boxShadow: 'inset 0 1px 0 #fff,0 0 0 1px rgba(20,22,26,.10)', zIndex: 2 },
  { left: '35.5%', top: '26.4%', width: '29%', height: '.6%', background: 'rgba(20,22,26,.10)', zIndex: 2 },
  { left: '30.5%', top: '32.5%', width: '6.5%', height: '15%', borderRadius: '12px 12px 6px 6px', background: 'linear-gradient(90deg,#182130,#222d3e)', zIndex: 3 },
  { left: '63%', top: '32.5%', width: '6.5%', height: '15%', borderRadius: '12px 12px 6px 6px', background: 'linear-gradient(90deg,#222d3e,#182130)', zIndex: 3 },
  { left: '45%', top: '35.4%', width: '10%', height: '4.4%', border: '3px solid #1c2636', borderBottom: 0, borderRadius: '999px 999px 0 0', zIndex: 3 },
  { left: '29%', top: '38%', width: '42%', height: '52%', borderRadius: '18% / 13%', background: 'linear-gradient(90deg,#1a2332 0%,#253146 50%,#1a2332 100%)', boxShadow: 'inset 0 2px 0 rgba(255,255,255,.07),0 22px 34px -16px rgba(10,20,40,.6)', zIndex: 3 },
  { left: '32.5%', top: '42%', width: '35%', height: '7%', borderTop: '2px solid #3a475d', borderRadius: '50% 50% 0 0 / 100% 100% 0 0', zIndex: 4 },
  { left: '65%', top: '42.6%', width: '1.6%', height: '3.4%', borderRadius: '2px', background: '#9aa6b8', zIndex: 4 },
  { left: '46.5%', top: '52%', width: '7%', height: '2.4%', borderRadius: '3px', background: '#3a475d', zIndex: 4 },
  { left: '34%', top: '60%', width: '32%', height: '24%', borderRadius: '16% / 20%', background: 'linear-gradient(180deg,#2b384d,#243043)', boxShadow: 'inset 0 1px 0 rgba(255,255,255,.07)', zIndex: 4 },
  { left: '37%', top: '64.2%', width: '26%', height: '.7%', borderRadius: '2px', background: '#4b5a73', zIndex: 5 },
  { left: '60.5%', top: '64.2%', width: '1.6%', height: '3.6%', borderRadius: '2px', background: '#9aa6b8', zIndex: 5 },
]

const SAFETY = [
  ['Thermal status', 'Normal', 'Stops if the Mac gets too warm'],
  ['Battery limit', '74% · stops at 20%', 'Or allow AC power only'],
  ['Time limit', '1 h 14 min left', 'Stops when the limit expires'],
]

const SUMMARY = [
  [{ background: '#3d8bff' }, 'Kept awake', '2 h 38 min'],
  [{ border: '1px solid #6b6b72' }, 'WakeGuard inactive', '0 min', '#c4c4ca'],
  [{ background: '#8e8e96' }, 'System sleep', '31 min'],
  [{ background: AMBER }, 'Unobserved time', '3 min'],
]

const PLUGIN_DOCS_URL = `${SOURCE_URL}/blob/main/docs/plugins.md`

const PLUGINS = [
  {
    id: 'a', name: 'Agent status', desc: 'Combined working, waiting and unavailable agent counts.',
    icon: <span className="pl-icon" style={{ gap: 3 }}><Dot size={5} color="#1462e0" /><Dot size={5} color="#d99a1e" /><Dot size={5} color="#a3a9b3" /></span>,
    perms: [['Agent activity', 'Counts only'], ['Menu bar panel', 'Show a status line'], ['Network', 'None']],
  },
  {
    id: 'n', name: 'Session notifications', desc: 'A macOS notification when a session starts or stops.',
    icon: <span className="pl-icon"><span style={{ position: 'relative', width: 16, height: 12, borderRadius: 3, border: '1.5px solid #1462e0', display: 'block' }}><Dot size={6} color="#1462e0" className="pl-badge-dot" /></span></span>,
    perms: [['Session events', 'Start and stop'], ['macOS notifications', 'Post notifications'], ['Network', 'None']],
  },
]

// Plugin status per id: 'none' → 'busy' (installing) → 'off' → 'on'.
const PLUGINS_RESET = { status: { a: 'none', n: 'none' }, sel: 'a', tab: 'avail' }

function PluginsPreview() {
  const [state, setState] = useState(PLUGINS_RESET)
  const [toast, setToast] = useState(false)
  const timers = useRef({})
  useEffect(() => () => Object.values(timers.current).forEach(clearTimeout), [])

  const { status, sel, tab } = state
  const setStatus = (id, st) => setState(s => ({ ...s, sel: id, status: { ...s.status, [id]: st } }))
  const install = id => {
    if (status[id] !== 'none') return
    setStatus(id, 'busy')
    timers.current[id] = setTimeout(() => setStatus(id, 'off'), 700)
  }
  const notify = () => {
    clearTimeout(timers.current.toast)
    setToast(true)
    timers.current.toast = setTimeout(() => setToast(false), 4200)
  }
  const reset = () => { Object.values(timers.current).forEach(clearTimeout); setToast(false); setState(PLUGINS_RESET) }

  const installed = id => status[id] === 'off' || status[id] === 'on'
  const count = PLUGINS.filter(p => installed(p.id)).length
  const visible = PLUGINS.filter(p => tab === 'avail' || installed(p.id))
  const d = PLUGINS.find(p => p.id === sel), st = status[sel], on = st === 'on'

  return (
    <>
      <div className="pl-stage">
        <div aria-live="polite" className="pl-toast-wrap">
          <div aria-hidden={!toast} className={`pl-toast${toast ? ' show' : ''}`}>
            <img src={ICON} alt="" width="30" height="30" style={{ borderRadius: 7, display: 'block', flex: 'none' }} />
            <div className="stack" style={{ gap: 2, minWidth: 0, flex: 1 }}>
              <div className="between" style={{ gap: 8, fontSize: 13 }}><span style={{ fontWeight: 650 }}>WakeGuard</span><span style={{ color: '#6a707a' }}>now</span></div>
              <span style={{ fontSize: 13, fontWeight: 550 }}>Session started</span>
              <span style={{ fontSize: 12.5, color: '#4a505a' }}>Keeping your Mac awake until agents finish.</span>
            </div>
          </div>
        </div>

        <div role="group" aria-label="WakeGuard Plugins window preview" className="pl-window">
          <div className="pl-titlebar">
            <div aria-hidden="true" style={{ display: 'flex', gap: 8 }}><Dot size={12} color="#ff5f57" /><Dot size={12} color="#febc2e" /><Dot size={12} color="#28c840" /></div>
            <div role="tablist" aria-label="Plugin list" className="pl-tabs">
              <button type="button" role="tab" aria-selected={tab === 'avail'} onClick={() => setState(s => ({ ...s, tab: 'avail' }))}>Available</button>
              <button type="button" role="tab" aria-selected={tab === 'inst'} onClick={() => setState(s => ({ ...s, tab: 'inst' }))}>Installed<span key={count} className="pl-count">{count}</span></button>
            </div>
            <span style={{ justifySelf: 'end', fontSize: 13, fontWeight: 600, color: '#3d424b' }}>Plugins</span>
          </div>

          <div style={{ padding: 8 }}>
            {visible.map(p => {
              const s = status[p.id]
              return (
                <div key={p.id} className={`pl-row${sel === p.id ? ' sel' : ''}`}>
                  {p.icon}
                  <button type="button" aria-pressed={sel === p.id} onClick={() => setState(x => ({ ...x, sel: p.id }))} className="pl-row-main">
                    <span style={{ fontWeight: 600, fontSize: 14.5 }}>{p.name}</span>
                    <span style={{ fontSize: 13, color: '#555b65', lineHeight: 1.4 }}>{p.desc}</span>
                  </button>
                  {installed(p.id)
                    ? <button type="button" role="switch" aria-checked={s === 'on'} aria-label={`Enable ${p.name}`} onClick={() => setStatus(p.id, s === 'on' ? 'off' : 'on')} className={`pl-switch${s === 'on' ? ' on' : ''}`}>
                        {s === 'on' ? 'Enabled' : 'Disabled'}<span className="pl-track"><span className="pl-knob" /></span>
                      </button>
                    : <button type="button" onClick={() => install(p.id)} className={`pl-install${s === 'busy' ? ' busy' : ''}`}>{s === 'busy' ? 'Installing…' : 'Install'}</button>}
                </div>
              )
            })}
            {visible.length === 0 && <div className="pl-empty">No plugins installed yet. Install one from Available.</div>}
          </div>

          <div className="pl-detail">
            <div className="between" style={{ alignItems: 'baseline', flexWrap: 'wrap' }}>
              <span style={{ fontWeight: 650, fontSize: 14.5 }}>{d.name}</span>
              <span className="row" style={{ gap: 7, fontSize: 12.5, color: on ? '#1462e0' : '#5b616b' }}>
                <Dot size={7} color={on ? '#1462e0' : installed(sel) ? '#a3a9b3' : 'transparent'} />
                {on ? 'Installed · Enabled' : st === 'off' ? 'Installed · Disabled' : st === 'busy' ? 'Installing…' : 'Not installed'}
              </span>
            </div>
            <div className="stack" style={{ gap: 6 }}>
              <span className="pl-label">Requested permissions</span>
              {d.perms.map(([label, value], i) => (
                <div key={sel + label} className="pl-perm" style={{ '--i': i }}><span style={{ color: '#3d424b' }}>{label}</span><span style={{ fontWeight: 550, textAlign: 'right' }}>{value}</span></div>
              ))}
            </div>
            {!on && <span key={sel + st} className="pl-pop" style={{ fontSize: 13, color: '#4a505a' }}>{installed(sel) ? 'Installed plugins stay disabled until you enable them.' : 'Review the permissions, then install. It won’t run until you enable it.'}</span>}
            {on && sel === 'a' && (
              <div className="pl-pop" style={{ display: 'grid', gridTemplateColumns: 'repeat(3,minmax(0,1fr))', gap: 8 }}>
                {[['3', 'Working', '#1462e0'], ['1', 'Waiting', '#d99a1e'], ['0', 'Unavailable', '#a3a9b3']].map(([n, label, c], i) => (
                  <div key={label} className="pl-stat" style={{ '--i': i }}><span className="row tnum" style={{ fontSize: 19, fontWeight: 700, gap: 7 }}><Dot size={7} color={c} className={i === 0 ? 'pulse' : ''} />{n}</span><span style={{ fontSize: 12, color: '#555b65' }}>{label}</span></div>
                ))}
              </div>
            )}
            {on && sel === 'n' && (
              <div className="pl-pop row" style={{ flexWrap: 'wrap', gap: '10px 14px' }}>
                <button type="button" onClick={notify} className="pl-sample">Start sample session</button>
                <span style={{ fontSize: 12.5, color: '#555b65' }}>Shows the session-start notification.</span>
              </div>
            )}
          </div>

          <div className="pl-footer">
            <button type="button" className="pl-ghost">Install from File…</button>
            <button type="button" className="pl-ghost">Install from URL…</button>
          </div>
        </div>
      </div>
      <div style={{ display: 'flex', justifyContent: 'flex-end', padding: '0 4px' }}>
        <button type="button" onClick={reset} className="pl-reset">Reset preview</button>
      </div>
    </>
  )
}

function Plugins() {
  return (
    <section id="plugins" aria-labelledby="plugins-title" className="wrap stack" style={{ paddingBottom: 'clamp(72px,10vw,136px)', scrollMarginTop: 60, gap: 16 }}>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 'clamp(40px,6vw,72px)', alignItems: 'center', borderTop: '1px solid rgba(20,22,26,.08)', paddingTop: 'clamp(56px,8vw,96px)' }}>
        <div className="stack" style={{ flex: '1 1 300px', minWidth: 0, maxWidth: 440, gap: 20 }}>
          <Reveal as="span" className="eyebrow">Plugins</Reveal>
          <Reveal as="h2" id="plugins-title" className="h2 words"><Words>Extend WakeGuard with plugins.</Words></Reveal>
          <Reveal as="p" delay={250} className="lead">Add agent status, session notifications, or build your own integration.</Reveal>
          <Reveal as="p" delay={350} className="muted" style={{ margin: 0, fontSize: 13.5, lineHeight: 1.55, textWrap: 'pretty' }}>Installed plugins stay disabled until you enable them. They don’t control sleep prevention. Optional integrations can make HTTPS requests.</Reveal>
        </div>
        <Reveal delay={200} className="stack" style={{ flex: '1.5 1 460px', minWidth: 0, maxWidth: '100%', gap: 12 }}>
          <PluginsPreview />
        </Reveal>
      </div>

      <Reveal className="card pl-dev">
        <div className="stack" style={{ flex: '1 1 280px', minWidth: 0, gap: 10 }}>
          <span className="eyebrow">For developers</span>
          <h3 style={{ margin: 0, fontSize: 22, letterSpacing: '-.015em' }}>Respond to WakeGuard events.</h3>
          <p>A plugin receives events and uses a small API to show status. Declare its permissions, then share it.</p>
          <div className="row" style={{ flexWrap: 'wrap', gap: '10px 20px', marginTop: 6 }}>
            <a href={PLUGIN_DOCS_URL} className="btn-nav">Build a plugin</a>
            <a href={`${SOURCE_URL}/pulls`} className="pl-link">Submit a plugin via pull request.</a>
          </div>
        </div>
        <pre aria-label="Example plugin code" className="pl-code"><code>
          <span className="pl-line" style={{ '--i': 0 }}><span style={{ color: '#7fb0ff' }}>function</span> <span style={{ color: '#f2f3f5', fontWeight: 600 }}>onEvent</span><span className="pl-punct">(</span>event<span className="pl-punct">,</span> api<span className="pl-punct">) {'{'}</span></span>
          <span className="pl-line" style={{ '--i': 1, paddingLeft: '2ch' }}>api<span className="pl-punct">.</span><span style={{ color: '#c9b6ff' }}>setStatus</span><span className="pl-punct">(</span>event<span className="pl-punct">.</span>agents<span className="pl-punct">.</span>working <span className="pl-punct">+</span> <span style={{ color: '#8fd19e' }}>" working"</span><span className="pl-punct">);</span></span>
          <span className="pl-line pl-punct" style={{ '--i': 2 }}>{'}'}<span className="pl-caret" /></span>
        </code></pre>
      </Reveal>
    </section>
  )
}

const KEYS = ['⌃ Control', '⌘ Command', 'Q']

const HOW_STEPS = [
  ['Start your agent task', 'Give Codex the task on your Mac.'],
  ['Start a WakeGuard session', 'Choose Manual or Until agents finish in the menu bar.'],
  ['Lock, then close the lid', 'Lock your Mac with Control–Command–Q, then close the lid.', true],
  ['Follow along on your phone', 'Follow progress and respond through Codex on your phone.'],
]

const MiniWindow = ({ bar, children }) => (
  <div className="mini-win">
    <div className="mini-bar">{bar}</div>
    {children}
  </div>
)

function Hero() {
  const [step, replay] = useDemo()
  const [awake, setAwake] = useState(true)
  const [agents, setAgents] = useState(true)
  // Hero visual tilts back and drifts up as it scrolls away.
  const heroRef = useScrollVar(r => -r.top / r.height)

  return (
    <section aria-labelledby="hero-title" className="wrap hero">
      <div className="stack" style={{ flex: '1 1 360px', minWidth: 0, maxWidth: 500, gap: 26 }}>
        <Reveal className="stack" style={{ alignItems: 'flex-start', gap: 6 }}>
          <LidStage step={step} />
          <span className="lid-chip">
            <img src={ICON} alt="" width="30" height="30" style={{ borderRadius: 8, display: 'block', flex: 'none' }} />
            <span className="stack" style={{ gap: 2, minWidth: 0 }}>
              <span className="row" style={{ gap: 8, fontSize: 14, fontWeight: 650 }}>
                <Dot color={awake ? '#1462e0' : '#a3a9b3'} className={awake && step > 0 ? 'pulse' : ''} />
                {!awake ? 'Off' : agents ? 'Awake · Until agents finish' : 'Awake · Manual'}
              </span>
              <span key={step === 0} className="lid-label">{step === 0 ? 'Lid open' : 'Lid closed · Codex keeps working'}</span>
            </span>
          </span>
        </Reveal>
        <Reveal delay={80} className="pill"><span className="beta">Beta</span>{RELEASE} · Free and open source</Reveal>
        <Reveal as="h1" id="hero-title" className="h1 words" delay={140}><Words>Full computer use.</Words><span style={{ color: '#1462e0' }}><Words from={3}>Lid closed.</Words></span></Reveal>
        <Reveal as="p" delay={480} style={{ margin: 0, fontSize: 'clamp(18px,1.6vw,21px)', lineHeight: 1.5, color: '#4a505a', textWrap: 'pretty', maxWidth: '30em' }}>Keep your Mac awake while Codex works across desktop apps, the browser and terminal—even with the lid closed.</Reveal>
        <Reveal className="row" delay={600} style={{ flexWrap: 'wrap', gap: 14 }}>
          <a href={DOWNLOAD_URL} className="btn-primary" style={{ whiteSpace: 'nowrap' }}>Download for macOS</a>
          <a href="#how" className="btn-secondary" style={{ whiteSpace: 'nowrap' }}>See how it works</a>
        </Reveal>
        <Reveal className="stack" delay={700} style={{ gap: 10 }}>
          <span style={{ fontSize: 14, color: '#3d424b', fontWeight: 550 }}>Apple Silicon · macOS 13+</span>
          <p className="info-note"><span aria-hidden="true" className="info-i">i</span><span>This beta isn’t notarized by Apple, so macOS asks you to confirm the first launch. <a href={SOURCE_URL} style={{ textDecoration: 'underline', textUnderlineOffset: 3 }}>Installation instructions</a></span></p>
        </Reveal>
      </div>

      <Reveal ref={heroRef} delay={250} className="hero-visual" style={{ flex: '1 1 400px', minWidth: 0, maxWidth: 520, marginLeft: 'auto' }}>
        <div role="group" aria-label="WakeGuard menu bar panel" className="frame" style={{ padding: 'clamp(52px,6vw,60px) clamp(14px,2.5vw,26px) clamp(20px,3vw,28px)', display: 'flex', flexWrap: 'wrap', gap: 20, alignItems: 'center', justifyContent: 'center' }}>
          <div aria-hidden="true" className="menubar">
            <span style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', width: 30, height: 22, borderRadius: 6, background: 'rgba(20,22,26,.14)' }}>
              <svg width="14" height="14" viewBox="0 0 16 16"><circle cx="8" cy="8" r="3.2" fill="none" stroke="#1d2026" strokeWidth="1.6" /><SunRays stroke="#1d2026" width="1.6" /></svg>
            </span>
            <span key={step} className="tick">{DEMO_TIMES[step]}</span>
          </div>
          <Panel step={step} awake={awake} setAwake={setAwake} agents={agents} setAgents={setAgents} />
        </div>
        <div style={{ margin: '12px 4px 0', display: 'flex', justifyContent: 'flex-end' }}>
          <button type="button" onClick={replay} className="pl-reset">Replay</button>
        </div>
      </Reveal>
    </section>
  )
}

function Capabilities() {
  return (
    <section id="capabilities" aria-labelledby="cap-title" className="wrap" style={{ paddingBottom: 'clamp(72px,10vw,128px)', scrollMarginTop: 60 }}>
      <div className="stack" style={{ gap: 16, marginBottom: 'clamp(36px,5vw,56px)' }}>
        <Reveal as="span" className="eyebrow">With the lid closed</Reveal>
        <Reveal as="h2" id="cap-title" className="h2 words"><Words>Codex keeps working across your Mac.</Words></Reveal>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,280px),1fr))', gap: 16 }}>
        <Reveal as="article" delay={0} className="card lift cap">
          <div aria-hidden="true" className="cap-illus">
            <MiniWindow bar={<><Dot size={6} color="#d3d7de" /><Dot size={6} color="#d3d7de" /><Dot size={6} color="#d3d7de" /><span style={{ marginLeft: 6, fontSize: 11, color: '#5b616b' }}>Slack · #release</span></>}>
              <div className="stack" style={{ padding: '8px 10px', gap: 7 }}>
                {[['#c9d6ea', '70%'], ['#f2d6a8', '82%'], ['#c9e3cf', '56%']].map(([c, w], i) => (
                  <div key={i} className="row cap-focus" style={{ gap: 7, '--i': i }}><span style={{ width: 14, height: 14, borderRadius: 4, background: c, flex: 'none' }} /><span style={{ height: 5, width: w, borderRadius: 3, background: '#e1e4e9' }} /></div>
                ))}
              </div>
            </MiniWindow>
          </div>
          <div className="stack" style={{ gap: 8 }}>
            <h3>Desktop apps</h3>
            <p>Let Codex inspect and interact with supported Mac apps through Computer Use.</p>
          </div>
        </Reveal>
        <Reveal as="article" delay={120} className="card lift cap">
          <div aria-hidden="true" className="cap-illus">
            <MiniWindow bar={<span className="mini-url">staging.example.app</span>}>
              <div style={{ padding: '9px 10px', display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 6 }}>
                {[0, 1, 2].map(i => <span key={i} className="cap-shot" style={{ '--i': i }} />)}
              </div>
              <div style={{ padding: '0 10px 8px', fontSize: 10.5, color: '#5b616b' }}>Screenshot 3 of 3 captured</div>
            </MiniWindow>
          </div>
          <div className="stack" style={{ gap: 8 }}>
            <h3>Browser</h3>
            <p>Keep testing websites, checking pages and capturing browser screenshots.</p>
          </div>
        </Reveal>
        <Reveal as="article" delay={240} className="card lift cap">
          <div aria-hidden="true" className="cap-illus cap-term">
            <span className="pl-line" style={{ '--i': 0 }}><span style={{ color: '#7fb0ff' }}>$</span> npm run build</span>
            <span className="pl-line" style={{ '--i': 1, color: '#8fd19e' }}>✓ 214 tests passed</span>
            <span className="pl-line" style={{ '--i': 2 }}><span style={{ color: '#7fb0ff' }}>$</span> ssh deploy@staging ./release.sh</span>
            <span className="pl-line cap-deploying" style={{ '--i': 3, color: '#8a909b' }}>Deploying<span>.</span><span>.</span><span>.</span></span>
          </div>
          <div className="stack" style={{ gap: 8 }}>
            <h3>Terminal</h3>
            <p>Keep builds, tests and SSH deployments running.</p>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

function HowItWorks() {
  return (
    <section id="how" aria-labelledby="how-title" style={{ borderTop: '1px solid rgba(20,22,26,.07)', background: '#fff', scrollMarginTop: 60 }}>
      <div className="wrap" style={{ paddingTop: 'clamp(72px,9vw,120px)', paddingBottom: 'clamp(72px,9vw,120px)' }}>
        <Reveal as="h2" id="how-title" className="h2 words" style={{ marginBottom: 'clamp(36px,5vw,56px)' }}><Words>Start it, lock it, close it.</Words></Reveal>
        <ol style={{ listStyle: 'none', margin: 0, padding: 0, display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,220px),1fr))', gap: 'clamp(28px,3.5vw,40px)' }}>
          {HOW_STEPS.map(([title, text, keys], i) => (
            <Reveal as="li" key={title} delay={i * 130} className="step">
              <span className="tnum" style={{ fontSize: 14, fontWeight: 600, color: '#1462e0' }}>0{i + 1}</span>
              <h3 style={{ fontSize: 21 }}>{title}</h3>
              <p>{text}</p>
              {keys && <span aria-hidden="true" style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>{KEYS.map((k, j) => <span key={k} className="key" style={{ '--i': j }}>{k}</span>)}</span>}
            </Reveal>
          ))}
        </ol>
        <Reveal as="p" delay={300} style={{ margin: 'clamp(32px,4vw,48px) 0 0', paddingTop: 18, borderTop: '1px solid rgba(20,22,26,.08)', fontSize: 14.5, lineHeight: 1.55, color: '#4a505a' }}>Deployments still need their normal network access.</Reveal>
      </div>
    </section>
  )
}

function useScrolled() {
  const [scrolled, setScrolled] = useState(false)
  useEffect(() => {
    const on = () => setScrolled(scrollY > 8)
    on()
    addEventListener('scroll', on, { passive: true })
    return () => removeEventListener('scroll', on)
  }, [])
  return scrolled
}

export default function App() {
  const scrolled = useScrolled()
  // Download card zooms up to full size as it enters.
  // Bag illustration: backdrop drifts slower than the figure as it passes through view.
  const bagRef = useScrollVar((r, vh) => (vh - r.top) / (vh + r.height))
  const ctaRef = useScrollVar((r, vh) => (vh - r.top) / (vh * 0.7))

  return (
    <div className="page">
      <header className={`header${scrolled ? ' scrolled' : ''}`}>
        <nav aria-label="Main" className="wrap nav">
          <a href="#top" aria-label="WakeGuard home" className="brand">
            <img src={ICON} alt="" width="28" height="28" style={{ borderRadius: 7, display: 'block' }} />
            <span>WakeGuard</span>
            <span className="beta soft">Beta</span>
          </a>
          <div className="navlinks">
            <a href="#capabilities">Capabilities</a>
            <a href="#how">How it works</a>
          </div>
          <a href={DOWNLOAD_URL} className="btn-nav">Download for macOS</a>
        </nav>
      </header>

      <main id="top">
        <Hero />

        <Capabilities />

        <HowItWorks />

        <Agents />

        <section aria-labelledby="lid-title" className="wrap split" style={{ paddingTop: 'clamp(72px,10vw,136px)' }}>
          <div className="stack" style={{ gap: 20, maxWidth: 500 }}>
            <Reveal as="span" className="eyebrow">Closed-lid work</Reveal>
            <Reveal as="h2" id="lid-title" className="h2 words"><Words>Close the lid. WakeGuard keeps watch.</Words></Reveal>
            <Reveal as="p" delay={250} className="lead">While your Mac works with the lid closed, WakeGuard keeps checking its thermal status, battery level and time limit. If the Mac gets too warm, the battery drops below your threshold or time runs out, it stops keeping the Mac awake.</Reveal>
            <Reveal as="p" delay={350} className="muted" style={{ margin: 0, fontSize: 14, lineHeight: 1.55 }}>Closed-lid operation depends on your power settings and the power source you allow.</Reveal>
          </div>
          <Reveal delay={150} className="card" style={{ borderRadius: 24, padding: 'clamp(20px,3vw,28px)', gap: 6, boxShadow: '0 1px 2px rgba(20,22,26,.04),0 30px 60px -36px rgba(20,40,80,.3)', maxWidth: 460, width: '100%', justifySelf: 'center' }}>
            <div className="between" style={{ alignItems: 'center', paddingBottom: 12 }}>
              <span style={{ fontWeight: 700, fontSize: 16 }}>Safety checks</span>
              <span className="row" style={{ gap: 7, fontSize: 13, color: '#1f7a3a', fontWeight: 550 }}><Dot color="#2fa553" className="pulse" />Monitoring</span>
            </div>
            {SAFETY.map(([label, value, hint], i) => (
              <Reveal key={label} delay={350 + i * 120} className="safety-row slide">
                <span style={{ fontSize: 15, fontWeight: 600 }}>{label}</span><span className="tnum" style={{ fontSize: 15 }}>{value}</span>
                <span className="muted" style={{ fontSize: 13.5 }}>{hint}</span><span />
              </Reveal>
            ))}
          </Reveal>

          <Reveal as="figure" ref={bagRef} className="bag" style={{ gridColumn: '1/-1' }}>
            <div role="img" aria-label="Illustration: a person seen from behind, walking with a backpack. A MacBook with its lid closed sticks out of the bag while WakeGuard keeps agents running." className="bag-stage">
              {BAG_BACKDROP.map((st, i) => (
                <div key={i} className={`bag-backdrop${i === 0 ? ' bag-glow' : i < 6 ? ' bag-bldg' : ''}`} style={{ ...st, '--i': i }} />
              ))}
              <div className="bag-walker">
                <div className="bag-bob">
                  {BAG_FIGURE.map((st, i) => <div key={i} style={st} />)}
                  <div className="bag-badge">
                    <div className="bag-ring" />
                    <div className="bag-ring" style={{ animationDelay: '1.2s' }} />
                    <img src={ICON} alt="" />
                  </div>
                </div>
              </div>
            </div>
            <div className="stack" style={{ gap: 12, padding: 'clamp(24px,4vw,48px)', alignSelf: 'center' }}>
              <figcaption className="stack" style={{ gap: 8, marginBottom: 8 }}>
                <Reveal as="span" className="words" style={{ fontSize: 'clamp(22px,2.4vw,28px)', fontWeight: 700, letterSpacing: '-.02em' }}><Words>In your bag. Still at work.</Words></Reveal>
                <Reveal as="span" delay={200} style={{ fontSize: 15.5, lineHeight: 1.55, color: '#3d4450', textWrap: 'pretty', maxWidth: '30em' }}>Close the lid and head out. WakeGuard keeps your agents running and lets the Mac sleep once they’re done. If it gets too warm in your bag, it stops.</Reveal>
              </figcaption>
              <Reveal delay={320} className="glass row" style={{ gap: 12 }}>
                <img src={ICON} alt="" width="34" height="34" style={{ borderRadius: 8, display: 'block' }} />
                <div className="stack" style={{ gap: 2, flex: 1, minWidth: 0 }}>
                  <span style={{ fontSize: 14.5, fontWeight: 650 }}>Awake · Until agents finish</span>
                  <span style={{ fontSize: 13.5, color: '#4a505a' }}>Lid closed · 42 min · Thermal status: Normal</span>
                </div>
              </Reveal>
              <Reveal delay={440} className="glass stack" style={{ gap: 9, fontSize: 14.5 }}>
                <span style={{ fontWeight: 650 }}>Agents</span>
                <div className="between"><span>Codex</span><span className="row" style={{ gap: 8, color: '#3d4450' }}><Dot color="#1462e0" className="pulse" />2 working</span></div>
                <div className="between"><span>Claude Code</span><span className="row" style={{ gap: 8, color: '#3d4450' }}><Dot color="#d99a1e" />1 waiting</span></div>
              </Reveal>
              <span style={{ fontSize: 12.5, color: '#4f5662', marginTop: 4 }}>Subject to power settings and safety limits</span>
            </div>
          </Reveal>
        </section>

        <Plugins />

        <section aria-labelledby="summary-title" className="wrap split" style={{ paddingTop: 'clamp(72px,10vw,136px)', paddingBottom: 'clamp(72px,10vw,136px)' }}>
          <div className="stack" style={{ gap: 20, maxWidth: 480 }}>
            <Reveal as="span" className="eyebrow">Session summary</Reveal>
            <Reveal as="h2" id="summary-title" className="h2 words"><Words>Know what happened while the lid was closed.</Words></Reveal>
            <Reveal as="p" delay={250} className="lead">When you reopen your Mac, WakeGuard shows how the time was spent. Unobserved time appears only when there’s a gap WakeGuard couldn’t see. Summaries cover only periods when WakeGuard was actively used.</Reveal>
          </div>
          <Reveal delay={150} style={{ background: '#242426', color: '#f2f2f4', borderRadius: 22, padding: 26, border: '1px solid rgba(255,255,255,.08)', boxShadow: '0 30px 60px -24px rgba(10,20,40,.45)', maxWidth: 440, width: '100%', justifySelf: 'center' }}>
            <div className="row" style={{ gap: 12 }}>
              <img src={ICON} alt="" width="32" height="32" style={{ borderRadius: 8, display: 'block' }} />
              <div className="stack" style={{ gap: 2 }}><span style={{ fontWeight: 700, fontSize: 16 }}>Welcome back</span><span style={{ fontSize: 13, color: '#a5a5ab' }}>Lid closed 16:40 – 19:52</span></div>
            </div>
            <div className="between" style={{ margin: '22px 0 18px', alignItems: 'baseline', flexWrap: 'wrap' }}>
              <span style={{ fontSize: 14, color: '#c4c4ca' }}>Closed-lid duration</span>
              <span className="tnum" style={{ fontSize: 30, fontWeight: 700, letterSpacing: '-.02em' }}>3 h 12 min</span>
            </div>
            <div aria-hidden="true" className="bar grow" style={{ height: 12, borderRadius: 6, marginBottom: 20 }}><span style={{ flex: 158, background: '#3d8bff' }} /><span style={{ flex: 31, background: '#8e8e96' }} /><span style={{ flex: 3, background: AMBER }} /></div>
            <dl className="stack" style={{ margin: 0, fontSize: 14.5 }}>
              {SUMMARY.map(([swatch, label, value, color], i) => (
                <Reveal key={label} delay={500 + i * 100} className="summary-row slide"><dt><span className="legend" style={swatch} />{label}</dt><dd style={{ color }}>{value}</dd></Reveal>
              ))}
            </dl>
          </Reveal>
        </section>

        <section id="download" aria-labelledby="privacy-title" className="wrap" style={{ paddingBottom: 'clamp(56px,8vw,96px)', scrollMarginTop: 60 }}>
          <div ref={ctaRef} className="dark stack cta-card" style={{ padding: 'clamp(36px,6vw,72px)', gap: 'clamp(40px,6vw,64px)' }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(min(100%,320px),1fr))', gap: '32px 64px' }}>
              <div className="stack" style={{ gap: 16 }}>
                <Reveal as="span" className="eyebrow">Open source · Local · Private</Reveal>
                <Reveal as="h2" id="privacy-title" className="h2 words" style={{ fontSize: 'clamp(30px,3.8vw,44px)' }}><Words>Open source. Runs entirely on your Mac.</Words></Reveal>
                <Reveal as="a" delay={350} href={SOURCE_URL} className="link-arrow">View source on GitHub →</Reveal>
              </div>
              <ul style={{ listStyle: 'none', margin: 0, padding: 0, display: 'flex', flexDirection: 'column', fontSize: 16, lineHeight: 1.5 }}>
                {['Free and open source. No account and no subscription service.', 'Core monitoring stays local. Optional plugins can connect to services you approve.', 'Activity logs never contain prompts, responses or conversation content.'].map((t, i) => (
                  <Reveal as="li" key={t} delay={150 + i * 110} className="slide" style={{ padding: '14px 0', borderBottom: i < 2 ? '1px solid rgba(255,255,255,.1)' : 0, display: 'flex', gap: 14 }}><span aria-hidden="true" style={{ color: '#7fb0ff' }}>—</span><span>{t}</span></Reveal>
                ))}
              </ul>
            </div>
            <div style={{ height: 1, background: 'rgba(255,255,255,.1)' }} />
            <Reveal className="row" style={{ flexWrap: 'wrap', justifyContent: 'space-between', gap: 28 }}>
              <div className="row" style={{ gap: 18 }}>
                <img src={ICON} alt="" width="64" height="64" style={{ borderRadius: 15, display: 'block', boxShadow: '0 10px 24px -10px rgba(40,120,255,.6)' }} />
                <div className="stack" style={{ gap: 4 }}>
                  <span style={{ fontSize: 'clamp(22px,2.4vw,28px)', fontWeight: 700, letterSpacing: '-.02em' }}>Get WakeGuard beta</span>
                  <span style={{ fontSize: 14, color: '#a9aeb8' }}>Apple Silicon · macOS 13+</span>
                  <span style={{ fontSize: 13, color: '#a9aeb8' }}>{RELEASE} · Not notarized · <a href={RELEASE_URL} style={{ color: '#7fb0ff' }}>Release notes</a></span>
                </div>
              </div>
              <a href={DOWNLOAD_URL} className="btn-cta" style={{ whiteSpace: 'nowrap' }}>Download for macOS</a>
            </Reveal>
          </div>
        </section>
      </main>

      <footer className="wrap muted" style={{ paddingBottom: 40, display: 'flex', flexWrap: 'wrap', justifyContent: 'space-between', gap: 12, fontSize: 13 }}>
        <span style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}><span>© 2026 WakeGuard · Open source</span><a href={SOURCE_URL} style={{ color: '#3d424b' }}>Source code</a><a href={RELEASE_URL} style={{ color: '#3d424b' }}>Release</a></span>
        <span>Beta. Closed-lid operation depends on power settings, safety limits and your Codex setup.</span>
      </footer>
    </div>
  )
}
