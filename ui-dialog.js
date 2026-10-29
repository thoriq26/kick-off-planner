/* ============================================================
   ui-dialog.js — dialog konfirmasi, peringatan, dan toast
   Dipakai bersama oleh halaman admin dan halaman member.
   Tidak bergantung pada Supabase; cukup dimuat setelah
   supabase-client.js (atau mandiri) dan sebelum skrip halaman.
   ============================================================ */
(() => {
    const KOP = (window.KOP = window.KOP || {});

    const STYLE_ID = "kop-ui-dialog-style";
    const TOAST_CONTAINER_ID = "kop-toast-container";
    let activeDialog = null;

    if (!document.getElementById(STYLE_ID)) {
        const style = document.createElement("style");
        style.id = STYLE_ID;
        style.textContent = `
            :root {
                --kop-green: #27ae60;
                --kop-green-dark: #1e8449;
                --kop-red: #e74c3c;
                --kop-red-dark: #c0392b;
                --kop-ink: #1e293b;
                --kop-muted: #64748b;
                --kop-line: #e2e8f0;
            }
            .kop-dialog-backdrop {
                position: fixed;
                inset: 0;
                z-index: 9998;
                display: flex;
                align-items: center;
                justify-content: center;
                padding: 18px;
                background: rgba(15, 23, 42, 0.58);
                backdrop-filter: blur(2px);
                animation: kop-fade-in 0.15s ease-out;
            }
            .kop-dialog {
                width: min(460px, 100%);
                max-height: min(86vh, 720px);
                overflow: auto;
                background: #ffffff;
                color: var(--kop-ink);
                border-radius: 16px;
                box-shadow: 0 24px 60px rgba(15, 23, 42, 0.35);
                font-family: "Poppins", "Segoe UI", system-ui, sans-serif;
                animation: kop-pop-in 0.18s ease-out;
            }
            .kop-dialog__head {
                display: flex;
                align-items: flex-start;
                gap: 12px;
                padding: 20px 22px 0;
            }
            .kop-dialog__icon {
                flex: none;
                width: 38px;
                height: 38px;
                border-radius: 50%;
                display: grid;
                place-items: center;
                background: #e8f8ef;
                color: var(--kop-green-dark);
                font-size: 1.05rem;
            }
            .kop-dialog--danger .kop-dialog__icon {
                background: #fdecea;
                color: var(--kop-red-dark);
            }
            .kop-dialog__title {
                margin: 4px 0 0;
                font-size: 1.05rem;
                line-height: 1.35;
                font-weight: 700;
            }
            .kop-dialog__body {
                margin: 12px 22px 0;
                padding-left: 50px;
                color: #334155;
                font-size: 0.92rem;
                line-height: 1.6;
                white-space: pre-line;
                overflow-wrap: anywhere;
            }
            .kop-dialog__actions {
                display: flex;
                flex-wrap: wrap;
                justify-content: flex-end;
                gap: 10px;
                padding: 22px 22px 20px;
            }
            .kop-dialog__actions button {
                min-height: 42px;
                padding: 10px 18px;
                border: 0;
                border-radius: 10px;
                font: inherit;
                font-weight: 700;
                font-size: 0.85rem;
                letter-spacing: 0.03em;
                cursor: pointer;
                transition: filter 0.15s ease, transform 0.1s ease;
            }
            .kop-dialog__actions button:hover { filter: brightness(0.94); }
            .kop-dialog__actions button:active { transform: translateY(1px); }
            .kop-dialog__ok {
                background: var(--kop-green);
                color: #ffffff;
            }
            .kop-dialog--danger .kop-dialog__ok {
                background: var(--kop-red);
            }
            .kop-dialog__cancel {
                background: #eef2f7;
                color: #334155;
            }
            .kop-toast-container {
                position: fixed;
                left: 50%;
                bottom: 22px;
                transform: translateX(-50%);
                z-index: 9999;
                display: flex;
                flex-direction: column;
                gap: 10px;
                width: min(440px, calc(100vw - 28px));
                pointer-events: none;
            }
            .kop-toast {
                display: flex;
                align-items: flex-start;
                gap: 10px;
                padding: 12px 14px;
                border-radius: 12px;
                background: #1e293b;
                color: #ffffff;
                font-family: "Poppins", "Segoe UI", system-ui, sans-serif;
                font-size: 0.88rem;
                line-height: 1.45;
                box-shadow: 0 14px 34px rgba(15, 23, 42, 0.28);
                opacity: 0;
                transform: translateY(10px);
                transition: opacity 0.18s ease, transform 0.18s ease;
                pointer-events: auto;
            }
            .kop-toast.is-visible {
                opacity: 1;
                transform: translateY(0);
            }
            .kop-toast--success { background: #1e8449; }
            .kop-toast--error { background: #c0392b; }
            .kop-toast--info { background: #1e3a5f; }
            .kop-toast__icon { flex: none; margin-top: 2px; }
            .kop-toast__text { flex: 1; overflow-wrap: anywhere; }
            .kop-toast__action,
            .kop-toast__close {
                flex: none;
                border: 0;
                background: rgba(255, 255, 255, 0.16);
                color: #ffffff;
                border-radius: 8px;
                font: inherit;
                font-size: 0.78rem;
                font-weight: 700;
                padding: 5px 10px;
                cursor: pointer;
            }
            .kop-toast__close {
                padding: 2px 8px;
                font-size: 1rem;
                line-height: 1.2;
            }
            .kop-toast__action:hover,
            .kop-toast__close:hover { background: rgba(255, 255, 255, 0.28); }
            button:focus-visible,
            a:focus-visible,
            select:focus-visible,
            input:focus-visible,
            textarea:focus-visible,
            [tabindex]:focus-visible {
                outline: 3px solid #f1c40f;
                outline-offset: 2px;
            }
            @keyframes kop-fade-in { from { opacity: 0; } to { opacity: 1; } }
            @keyframes kop-pop-in {
                from { opacity: 0; transform: translateY(8px) scale(0.985); }
                to { opacity: 1; transform: translateY(0) scale(1); }
            }
            @media (prefers-reduced-motion: reduce) {
                .kop-dialog-backdrop,
                .kop-dialog,
                .kop-toast { animation: none; transition: none; }
            }
            @media (max-width: 420px) {
                .kop-dialog__head { padding: 18px 16px 0; }
                .kop-dialog__body { margin: 10px 16px 0; padding-left: 0; }
                .kop-dialog__actions { padding: 18px 16px 16px; }
                .kop-dialog__actions button { flex: 1 1 auto; }
            }
        `;
        document.head.appendChild(style);
    }

    function toastContainer() {
        let container = document.getElementById(TOAST_CONTAINER_ID);
        if (!container) {
            container = document.createElement("div");
            container.id = TOAST_CONTAINER_ID;
            container.className = "kop-toast-container";
            container.setAttribute("aria-live", "polite");
            document.body.appendChild(container);
        }
        return container;
    }

    /**
     * Notifikasi ringkas yang hilang otomatis.
     * @param {string} message
     * @param {"success"|"error"|"info"} [type]
     * @param {{duration?: number, actionLabel?: string, onAction?: Function}} [options]
     */
    function toast(message, type = "info", options = {}) {
        const safeType = ["success", "error", "info"].includes(type) ? type : "info";
        const icons = {
            success: "fa-solid fa-circle-check",
            error: "fa-solid fa-triangle-exclamation",
            info: "fa-solid fa-circle-info",
        };
        const node = document.createElement("div");
        node.className = `kop-toast kop-toast--${safeType}`;
        node.setAttribute("role", safeType === "error" ? "alert" : "status");

        const icon = document.createElement("i");
        icon.className = `kop-toast__icon ${icons[safeType]}`;
        icon.setAttribute("aria-hidden", "true");

        const text = document.createElement("span");
        text.className = "kop-toast__text";
        text.textContent = String(message ?? "");

        node.append(icon, text);

        let timer = null;
        const remove = () => {
            if (timer) clearTimeout(timer);
            node.classList.remove("is-visible");
            setTimeout(() => node.remove(), 180);
        };

        if (options.actionLabel && typeof options.onAction === "function") {
            const action = document.createElement("button");
            action.type = "button";
            action.className = "kop-toast__action";
            action.textContent = options.actionLabel;
            action.addEventListener("click", () => {
                remove();
                options.onAction();
            });
            node.appendChild(action);
        }

        const close = document.createElement("button");
        close.type = "button";
        close.className = "kop-toast__close";
        close.setAttribute("aria-label", "Tutup notifikasi");
        close.textContent = "\u00d7";
        close.addEventListener("click", remove);
        node.appendChild(close);

        toastContainer().appendChild(node);
        requestAnimationFrame(() => node.classList.add("is-visible"));
        timer = setTimeout(remove, Math.max(2000, options.duration || (safeType === "error" ? 8000 : 5000)));
        return { close: remove };
    }

    /**
     * Dialog modal. Mengembalikan Promise<boolean>.
     * @param {{title?: string, message?: string, okLabel?: string,
     *          cancelLabel?: string|null, danger?: boolean}} options
     */
    function showDialog(options = {}) {
        const {
            title = "Konfirmasi",
            message = "",
            okLabel = "Lanjutkan",
            cancelLabel = "Batal",
            danger = false,
        } = options;

        // Hanya satu dialog aktif; dialog sebelumnya dianggap dibatalkan.
        if (activeDialog) activeDialog.close(false);

        return new Promise((resolve) => {
            const previouslyFocused = document.activeElement;
            const titleId = `kop-dialog-title-${Date.now()}`;
            const backdrop = document.createElement("div");
            backdrop.className = "kop-dialog-backdrop";

            const dialog = document.createElement("div");
            dialog.className = `kop-dialog${danger ? " kop-dialog--danger" : ""}`;
            dialog.setAttribute("role", "dialog");
            dialog.setAttribute("aria-modal", "true");
            dialog.setAttribute("aria-labelledby", titleId);

            const head = document.createElement("div");
            head.className = "kop-dialog__head";

            const icon = document.createElement("span");
            icon.className = "kop-dialog__icon";
            icon.setAttribute("aria-hidden", "true");
            const iconEl = document.createElement("i");
            iconEl.className = danger ? "fa-solid fa-triangle-exclamation" : "fa-solid fa-circle-question";
            icon.appendChild(iconEl);

            const heading = document.createElement("h2");
            heading.className = "kop-dialog__title";
            heading.id = titleId;
            heading.textContent = title;
            head.append(icon, heading);

            const body = document.createElement("div");
            body.className = "kop-dialog__body";
            body.textContent = message;

            const actions = document.createElement("div");
            actions.className = "kop-dialog__actions";

            const cancelButton = cancelLabel ? document.createElement("button") : null;
            if (cancelButton) {
                cancelButton.type = "button";
                cancelButton.className = "kop-dialog__cancel";
                cancelButton.textContent = cancelLabel;
                cancelButton.addEventListener("click", () => close(false));
                actions.appendChild(cancelButton);
            }

            const okButton = document.createElement("button");
            okButton.type = "button";
            okButton.className = "kop-dialog__ok";
            okButton.textContent = okLabel;
            okButton.addEventListener("click", () => close(true));
            actions.appendChild(okButton);

            dialog.append(head, body, actions);
            backdrop.appendChild(dialog);
            document.body.appendChild(backdrop);

            const focusables = () => Array.from(
                dialog.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'),
            ).filter((element) => !element.disabled && element.offsetParent !== null);

            function onKeyDown(event) {
                if (event.key === "Escape") {
                    event.preventDefault();
                    close(false);
                    return;
                }
                if (event.key !== "Tab") return;
                const items = focusables();
                if (!items.length) return;
                const first = items[0];
                const last = items[items.length - 1];
                if (event.shiftKey && document.activeElement === first) {
                    event.preventDefault();
                    last.focus();
                } else if (!event.shiftKey && document.activeElement === last) {
                    event.preventDefault();
                    first.focus();
                }
            }

            function onPointerDown(event) {
                if (event.target === backdrop) close(false);
            }

            let closed = false;
            function close(result) {
                if (closed) return;
                closed = true;
                document.removeEventListener("keydown", onKeyDown, true);
                backdrop.removeEventListener("pointerdown", onPointerDown);
                backdrop.remove();
                activeDialog = null;
                if (previouslyFocused && typeof previouslyFocused.focus === "function") {
                    try {
                        previouslyFocused.focus();
                    } catch {
                        /* elemen pemicu mungkin sudah tidak ada */
                    }
                }
                resolve(result);
            }

            activeDialog = { close };
            document.addEventListener("keydown", onKeyDown, true);
            backdrop.addEventListener("pointerdown", onPointerDown);
            (cancelButton ? cancelButton : okButton).focus();
        });
    }

    function alert(message, options = {}) {
        return showDialog({
            title: options.title || "Informasi",
            message,
            okLabel: options.okLabel || "Mengerti",
            cancelLabel: null,
            danger: Boolean(options.danger),
        });
    }

    function confirm(options = {}) {
        return showDialog({
            title: options.title || "Konfirmasi",
            message: options.message || options.pesan || "",
            okLabel: options.okLabel || options.labelOk || "Lanjutkan",
            cancelLabel: options.cancelLabel === null
                ? null
                : options.cancelLabel || options.labelBatal || "Batal",
            danger: Boolean(options.danger || options.bahaya),
        });
    }

    KOP.ui = {
        toast,
        alert,
        confirm,
        isOpen: () => Boolean(activeDialog),
    };
})();
