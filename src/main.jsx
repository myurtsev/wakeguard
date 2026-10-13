import { hydrateRoot, createRoot } from 'react-dom/client'
import App from './App.jsx'
import './index.css'

const root = document.getElementById('root')
if (root.hasChildNodes()) hydrateRoot(root, <App />)
else createRoot(root).render(<App />)
