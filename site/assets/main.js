/**
 * Mornye Network Storage — Client Interactions Engine
 * Zero dependencies, ultra-fast, accessible, luxury interactive feel.
 * Engineered by NavyaXdev
 */

// 0. Domain Migration: Consolidate legacy GitHub Pages traffic onto the official custom domain
(function() {
  if (typeof window !== 'undefined' && window.location && window.location.hostname) {
    if (window.location.hostname.indexOf('github.io') !== -1) {
      var path = window.location.pathname.replace(/^\/Mornye-Network-Storage/, '');
      if (!path || !path.startsWith('/')) path = '/' + (path || '');
      window.location.replace('https://mornye-network-project.navya.dpdns.org' + path + window.location.search + window.location.hash);
    }
  }
})();

document.addEventListener('DOMContentLoaded', () => {
  // 1. Sticky Header Scroll Effect
  const header = document.querySelector('.site-header');
  if (header) {
    const handleScroll = () => {
      if (window.scrollY > 20) {
        header.classList.add('scrolled');
      } else {
        header.classList.remove('scrolled');
      }
    };
    window.addEventListener('scroll', handleScroll, { passive: true });
    handleScroll();
  }

  // 2. Mobile Navigation Drawer Toggle
  const navToggle = document.querySelector('.nav-toggle');
  const navLinks = document.querySelector('.nav-links');

  if (navToggle && navLinks) {
    navToggle.addEventListener('click', () => {
      const isExpanded = navToggle.getAttribute('aria-expanded') === 'true';
      navToggle.setAttribute('aria-expanded', !isExpanded);
      navLinks.classList.toggle('active');
    });

    // Close menu when clicking outside
    document.addEventListener('click', (e) => {
      if (!navToggle.contains(e.target) && !navLinks.contains(e.target) && navLinks.classList.contains('active')) {
        navToggle.setAttribute('aria-expanded', 'false');
        navLinks.classList.remove('active');
      }
    });
  }

  // 3. Interactive Code Copy Buttons with Rich Feedback
  document.querySelectorAll('.btn-copy, .copy-btn').forEach(button => {
    button.addEventListener('click', async () => {
      const targetSelector = button.getAttribute('data-target');
      let textToCopy = '';

      if (targetSelector) {
        // Try getElementById first, then querySelector
        const targetEl = document.getElementById(targetSelector) || document.querySelector(targetSelector) || document.querySelector(`[data-target="${targetSelector}"]`);
        if (targetEl) textToCopy = targetEl.innerText.trim();
      }
      
      if (!textToCopy) {
        const container = button.closest('.terminal-header')?.nextElementSibling || button.closest('.terminal-card, .terminal-body, .quickstart-box, pre');
        const codeEl = container ? container.querySelector('code, pre, .terminal-code') : null;
        if (codeEl) textToCopy = codeEl.innerText.trim();
      }

      if (textToCopy) {
        // Strip leading "$ " if present
        if (textToCopy.startsWith('$ ')) {
          textToCopy = textToCopy.substring(2).trim();
        }

        try {
          await navigator.clipboard.writeText(textToCopy);
          const originalHTML = button.innerHTML;
          button.innerHTML = `
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#10b981" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="20 6 9 17 4 12"></polyline>
            </svg>
            <span style="color: #10b981; font-weight: 600;">Copied!</span>
          `;
          button.style.borderColor = 'rgba(16, 185, 129, 0.5)';
          button.style.background = 'rgba(16, 185, 129, 0.12)';

          setTimeout(() => {
            button.innerHTML = originalHTML;
            button.style.borderColor = '';
            button.style.background = '';
          }, 2000);
        } catch (err) {
          console.error('Clipboard copy failed:', err);
        }
      }
    });
  });

  // 4. Luxury FAQ Accordion Interactive Engine
  document.querySelectorAll('.faq-question').forEach(button => {
    button.addEventListener('click', () => {
      const item = button.closest('.faq-item');
      const isExpanded = button.getAttribute('aria-expanded') === 'true';
      const answer = button.nextElementSibling;

      // Close other accordion items in the same container for clean accordion UX
      const parent = button.closest('.faq-container, div');
      if (parent && !isExpanded) {
        parent.querySelectorAll('.faq-question[aria-expanded="true"]').forEach(otherBtn => {
          if (otherBtn !== button) {
            otherBtn.setAttribute('aria-expanded', 'false');
            const otherItem = otherBtn.closest('.faq-item');
            if (otherItem) otherItem.classList.remove('active');
            const otherAns = otherBtn.nextElementSibling;
            if (otherAns && otherAns.classList.contains('faq-answer')) {
              otherAns.hidden = true;
            }
          }
        });
      }

      button.setAttribute('aria-expanded', !isExpanded);
      if (item) {
        if (!isExpanded) {
          item.classList.add('active');
        } else {
          item.classList.remove('active');
        }
      }
      if (answer && answer.classList.contains('faq-answer')) {
        answer.hidden = isExpanded;
      }
    });
  });
});
