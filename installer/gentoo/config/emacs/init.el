(menu-bar-mode -1)
(tool-bar-mode -1)

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(add-to-list 'package-archives '("nongnu" . "https://elpa.nongnu.org/nongnu/") t)
(package-initialize)
(package-refresh-contents)

(unless (package-installed-p 'use-package)
  (package-install 'use-package))

(eval-when-compile (require 'use-package))

(use-package vterm :ensure t)

(setq evil-want-keybinding nil)
(use-package evil :ensure t)
(evil-mode 1)

(use-package evil-collection :ensure t)
(evil-collection-init)

(use-package all-the-icons :ensure t)

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
