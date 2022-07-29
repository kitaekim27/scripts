(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(add-to-list 'package-archives '("nongnu" . "https://elpa.nongnu.org/nongnu/") t)
(package-initialize)

(unless (package-installed-p 'use-package)
  (package-install 'use-package))

(eval-when-compile
  (require 'use-package))

(use-package vterm :ensure t)

(setq evil-want-keybinding nil)
(use-package evil :ensure t)
(evil-mode 1)

(use-package evil-collection :ensure t)
(evil-collection-init)
