function copyCommand() {
    const commandText = document.getElementById('installCommand');
    const copyBtn = document.querySelector('.copy-btn');
    const btnText = copyBtn.querySelector('.btn-text');

    // Select and copy the text
    commandText.select();
    commandText.setSelectionRange(0, 99999); // For mobile devices

    navigator.clipboard.writeText(commandText.value).then(() => {
        // Update button to show success
        copyBtn.classList.add('copied');
        btnText.textContent = 'Copied!';

        // Reset button after 2 seconds
        setTimeout(() => {
            copyBtn.classList.remove('copied');
            btnText.textContent = 'Copy';
        }, 2000);
    }).catch(err => {
        console.error('Failed to copy:', err);
        // Fallback for older browsers
        try {
            document.execCommand('copy');
            copyBtn.classList.add('copied');
            btnText.textContent = 'Copied!';
            setTimeout(() => {
                copyBtn.classList.remove('copied');
                btnText.textContent = 'Copy';
            }, 2000);
        } catch (e) {
            alert('Failed to copy. Please copy manually.');
        }
    });
}

// Allow clicking on the command text to copy
document.getElementById('installCommand').addEventListener('click', function () {
    this.select();
});

document.addEventListener('DOMContentLoaded', () => {
    const themeToggleBtn = document.getElementById('themeToggleBtn');
    const themeIcon = document.getElementById('themeIcon');
    const themeText = document.getElementById('themeText');

    const systemDark = window.matchMedia('(prefers-color-scheme: dark)');

    // Apply theme, falling back to system preference if no manual override
    function applyTheme(theme) {
        document.documentElement.setAttribute('data-theme', theme);
        updateToggleButton(theme);
    }

    const savedTheme = localStorage.getItem('theme');
    applyTheme(savedTheme || (systemDark.matches ? 'dark' : 'light'));

    // Follow system changes automatically unless the user has manually chosen a theme
    systemDark.addEventListener('change', (e) => {
        if (!localStorage.getItem('theme')) {
            applyTheme(e.matches ? 'dark' : 'light');
        }
    });

    themeToggleBtn.addEventListener('click', () => {
        const currentTheme = document.documentElement.getAttribute('data-theme');
        const newTheme = currentTheme === 'light' ? 'dark' : 'light';

        localStorage.setItem('theme', newTheme);
        applyTheme(newTheme);
    });

    function updateToggleButton(theme) {
        if (theme === 'light') {
            themeIcon.innerHTML = '<circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line>';
            themeText.textContent = 'Light Mode';
        } else {
            themeIcon.innerHTML = '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path>';
            themeText.textContent = 'Dark Mode';
        }
    }
});
