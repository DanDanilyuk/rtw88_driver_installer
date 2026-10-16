// localStorage can throw (blocked storage, some private modes); never let
// that break the page.
function storageGet(key) {
    try {
        return localStorage.getItem(key);
    } catch (e) {
        return null;
    }
}

function storageSet(key, value) {
    try {
        localStorage.setItem(key, value);
    } catch (e) {
        // Ignore: the choice still applies for this visit.
    }
}

document.addEventListener('DOMContentLoaded', () => {
    // ── Copy install command ──

    const commandEl = document.getElementById('installCommand');
    const copyBtn = document.querySelector('.copy-btn');
    const btnText = copyBtn.querySelector('.btn-text');
    const copyStatus = document.getElementById('copyStatus');
    const isMac = /Mac|iPhone|iPad/.test(navigator.platform || '');
    let resetTimer;

    function showCopyResult(ok) {
        clearTimeout(resetTimer);
        copyBtn.classList.toggle('copied', ok);
        btnText.textContent = ok ? 'Copied!' : (isMac ? 'Press ⌘C' : 'Press Ctrl+C');
        copyStatus.textContent = ok
            ? 'Install command copied to clipboard.'
            : 'Copying failed. The command is selected, so press ' + (isMac ? 'Command+C' : 'Ctrl+C') + ' to copy it.';

        resetTimer = setTimeout(() => {
            copyBtn.classList.remove('copied');
            btnText.textContent = 'Copy';
            copyStatus.textContent = '';
        }, ok ? 2000 : 4000);
    }

    // Select the command so a manual copy is one keystroke away.
    function selectCommand() {
        const range = document.createRange();
        range.selectNodeContents(commandEl);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
    }

    // Fallback for browsers without the async Clipboard API (or outside a
    // secure context, where navigator.clipboard is undefined).
    function legacyCopy(text) {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.top = '0';
        ta.style.left = '0';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        let ok = false;
        try {
            ok = document.execCommand('copy');
        } catch (e) {
            ok = false;
        }
        document.body.removeChild(ta);
        copyBtn.focus();
        return ok;
    }

    copyBtn.addEventListener('click', () => {
        const text = commandEl.textContent.trim();
        const finish = (ok) => {
            if (!ok) selectCommand();
            showCopyResult(ok);
        };

        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(
                () => finish(true),
                () => finish(legacyCopy(text))
            );
        } else {
            finish(legacyCopy(text));
        }
    });

    // ── Theme toggle ──

    const root = document.documentElement;
    const themeToggleBtn = document.getElementById('themeToggleBtn');
    const themeIcon = document.getElementById('themeIcon');
    const themeText = document.getElementById('themeText');
    const themeColorMeta = document.querySelector('meta[name="theme-color"]');
    const systemDark = window.matchMedia('(prefers-color-scheme: dark)');

    // Remembered in memory too, so a manual choice sticks for this visit
    // even when localStorage is unavailable.
    let manualTheme = storageGet('theme');

    function applyTheme(theme) {
        root.setAttribute('data-theme', theme);
        if (themeColorMeta) {
            themeColorMeta.setAttribute('content', theme === 'light' ? '#f2f4f7' : '#13161b');
        }
        updateToggleButton(theme);
    }

    function updateToggleButton(theme) {
        if (theme === 'light') {
            themeIcon.innerHTML = '<circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line>';
            themeText.textContent = 'Light Mode';
            themeToggleBtn.setAttribute('aria-pressed', 'false');
        } else {
            themeIcon.innerHTML = '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path>';
            themeText.textContent = 'Dark Mode';
            themeToggleBtn.setAttribute('aria-pressed', 'true');
        }
    }

    applyTheme(manualTheme || (systemDark.matches ? 'dark' : 'light'));

    // Follow system changes automatically unless the user has manually chosen a theme
    const onSystemChange = (e) => {
        if (!manualTheme) {
            applyTheme(e.matches ? 'dark' : 'light');
        }
    };
    if (systemDark.addEventListener) {
        systemDark.addEventListener('change', onSystemChange);
    } else if (systemDark.addListener) {
        systemDark.addListener(onSystemChange);
    }

    themeToggleBtn.addEventListener('click', () => {
        manualTheme = root.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
        storageSet('theme', manualTheme);
        applyTheme(manualTheme);
    });
});
