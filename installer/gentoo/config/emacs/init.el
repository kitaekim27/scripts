(menu-bar-mode -1)
(scroll-bar-mode -1)
(tool-bar-mode -1)

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(add-to-list 'package-archives '("nongnu" . "https://elpa.nongnu.org/nongnu/") t)
(package-initialize)

(unless (package-installed-p 'use-package)
  (package-install 'use-package))

(eval-when-compile (require 'use-package))

(use-package vterm
  :ensure t
  :config
  (setq vterm-kill-buffer-on-exit t))

(use-package evil
  :ensure t
  :init
  (setq evil-want-keybinding nil)
  :config
  (setq evil-want-C-u-scroll t)
  (evil-mode 1))

(use-package evil-collection
  :ensure t
  :config
  (evil-collection-init))

(use-package all-the-icons
  :ensure t
  :if (display-graphic-p))

(use-package doom-themes
  :ensure t
  :config
  (setq doom-themes-enable-bold t
        doom-themes-enable-italic t)
  (load-theme 'doom-one t)
  (doom-themes-visual-bell-config)
  (doom-themes-neotree-config)
  (setq doom-themes-treemacs-theme "doom-atom")
  (doom-themes-treemacs-config)
  (doom-themes-org-config))

(use-package doom-modeline :ensure t
  :init (doom-modeline-mode 1))
