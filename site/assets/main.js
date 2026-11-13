/**
 * Mornye Network Storage - Client Scripts
 * Zero dependencies, high performance, accessible.
 */

document.addEventListener('DOMContentLoaded', () => {
  // 1. Mobile Navigation Toggle
  const navToggle = document.querySelector('.nav-toggle');
  const navLinks = document.querySelector('.nav-links');

  if (navToggle && navLinks) {
    navToggle.addEventListener('click', () => {
      const isExpanded = navToggle.getAttribute('aria-expanded') === 'true';
      navToggle.setAttribute('aria-expanded', !isExpanded);
      navLinks.classList.toggle('active');
    });
  }

  // 2. Copy Code Snippet Buttons
  document.querySelectorAll('.btn-copy').forEach(button => {
    button.addEventListener('click', async () => {
      const targetSelector = button.getAttribute('data-target');
      let textToCopy = '';

      if (targetSelector) {
        const targetEl = document.querySelector(targetSelector);
        if (targetEl) textToCopy = targetEl.innerText.trim();
      } else {
        const pre = button.closest('.quickstart-box, .code-wrapper')?.querySelector('code, .quickstart-code');
        if (pre) textToCopy = pre.innerText.trim();
      }

      if (textToCopy) {
        // Strip leading "$ " if present
        if (textToCopy.startsWith('$ ')) {
          textToCopy = textToCopy.substring(2).trim();
        }

        try {
          await navigator.clipboard.writeText(textToCopy);
          const originalHTML = button.innerHTML;
          button.innerHTML = '<span>✓ Copied!</span>';
          button.style.borderColor = 'var(--accent-green)';
          button.style.color = 'var(--accent-green)';

          setTimeout(() => {
            button.innerHTML = originalHTML;
            button.style.borderColor = '';
            button.style.color = '';
          }, 2000);
        } catch (err) {
          console.error('Clipboard copy failed:', err);
        }
      }
    });
  });

  // 3. FAQ Accordion Toggle (if used with .faq-question)
  document.querySelectorAll('.faq-question').forEach(button => {
    button.addEventListener('click', () => {
      const isExpanded = button.getAttribute('aria-expanded') === 'true';
      button.setAttribute('aria-expanded', !isExpanded);
      const answer = button.nextElementSibling;
      if (answer && answer.classList.contains('faq-answer')) {
        answer.hidden = isExpanded;
      }
    });
  });

  // 4. Base Path Normalizer (Cross-compatibility for Root Domains / Cloudflare Workers and GitHub Pages)
  if (!window.location.pathname.startsWith('/Mornye-Network-Storage')) {
    document.querySelectorAll('a[href^="/Mornye-Network-Storage/"]').forEach(link => {
      const currentHref = link.getAttribute('href');
      const newHref = currentHref.replace(/^\/Mornye-Network-Storage/, '') || '/';
      link.setAttribute('href', newHref);
    });
  }
});

