(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript visual support dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptVisualSupportFactory = function createChatTranscriptVisualSupport(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");

    const readexAccentPalette = [
      "#2F8CFF",
      "#22C7D8",
      "#20C997",
      "#35C759",
      "#F2A93B",
      "#FF4D7D",
      "#C06BFF",
      "#6C63FF",
      "#8B5CF6",
      "#38BDF8",
      "#2DD4BF",
      "#FF6B5F"
    ];

    function readexStableColorIndex(seed, count) {
      const text = trimmed(seed);
      if (!text || !Number.isFinite(count) || count <= 0) {
        return 0;
      }
      let hash = 2166136261;
      for (let index = 0; index < text.length; index += 1) {
        hash ^= text.charCodeAt(index);
        hash = Math.imul(hash, 16777619);
      }
      return Math.abs(hash >>> 0) % count;
    }

    function readexAccentColor(seed) {
      return readexAccentPalette[
        readexStableColorIndex(seed, readexAccentPalette.length)
      ];
    }

    function systemSymbolMarkup(name, variant) {
      const catalog = window.__chatTranscriptSystemSymbols || {};
      const toolbarSymbols = catalog.toolbar && typeof catalog.toolbar === "object"
        ? catalog.toolbar
        : {};
      if (name === "spinner-legacy") {
        const animatedDataURL = trimmed(catalog.spinnerLegacyAnimated);
        if (animatedDataURL) {
          return `<img src="${animatedDataURL}" alt="" aria-hidden="true">`;
        }
        return '<img src="Math/legacy-spinner.apng" alt="" aria-hidden="true">';
      }

      let dataURL = "";
      if (variant === "assistant-model-picker-selected-check") {
        dataURL = trimmed(catalog.modelPickerCheck);
      } else if (name === "spinner-legacy") {
        dataURL = trimmed(catalog.spinnerLegacy);
      } else {
        dataURL = trimmed(toolbarSymbols[name]);
      }

      if (!dataURL) {
        return "";
      }

      return `<span class="sf-symbol-mask" style="--sf-symbol-mask: url('${dataURL}');"></span>`;
    }

    function makeIcon(name, variant = "") {
      const systemMarkup = systemSymbolMarkup(name, variant);
      if (systemMarkup) {
        return systemMarkup;
      }

      const svgByName = {
        magnifyingglass:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5" fill="none" stroke="currentColor" stroke-width="2.2"></circle><path d="M16 16l5 5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.2"></path></svg>',
        lightbulb:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 18h6" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path><path d="M10 21h4" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path><path d="M8.2 15.5c-1.8-1.4-3.2-3.5-3.2-6 0-4 3.1-7 7-7s7 3 7 7c0 2.5-1.4 4.6-3.2 6-.9.7-1.8 1.8-1.8 3H10c0-1.2-.9-2.3-1.8-3z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path></svg>',
        sparkles:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l1.7 4.6L18 9.3l-4.3 1.7L12 15.5 10.3 11 6 9.3l4.3-1.7L12 3z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="1.9"></path><path d="M18.5 14l.9 2.4 2.1.8-2.1.8-.9 2.5-.9-2.5-2.1-.8 2.1-.8.9-2.4zM5.5 13l.7 1.9 1.8.7-1.8.7-.7 1.9-.7-1.9-1.8-.7 1.8-.7.7-1.9z" fill="currentColor"></path></svg>',
        "chevron-right":
          '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M3 1.5L6.5 5 3 8.5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.6"></path></svg>',
        "chevron-down":
          '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M1.5 3L5 6.5 8.5 3" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.6"></path></svg>',
        doc:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 3.5h7l4 4V20a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 20V5A1.5 1.5 0 0 1 7.5 3.5z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M14 3.5V8h4" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path></svg>',
        folder:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 7.5c0-1.1.9-2 2-2h4.1c.7 0 1.2.2 1.7.7l1.3 1.3h5.9c1.1 0 2 .9 2 2v7.8c0 1.2-.9 2.2-2.2 2.2H5.7c-1.2 0-2.2-1-2.2-2.2V7.5z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path></svg>',
        photo:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3.5" y="5" width="17" height="14" rx="2.5" fill="none" stroke="currentColor" stroke-width="2"></rect><circle cx="9" cy="10" r="1.5" fill="currentColor"></circle><path d="M6 17l4.2-4.4 3.3 3.2 2.4-2.6L18 17" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2"></path></svg>',
        "terminal-square":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3.55" y="3.55" width="16.9" height="16.9" rx="2.9" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="1.9"></rect><path d="M7.95 9.65l2.95 2.35-2.95 2.35" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.9"></path><path d="M14.2 14.55h2.65" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="1.9"></path></svg>',
        "arrow-clockwise":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 5v5h-5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path><path d="M20 10a8 8 0 1 0 2 5.3" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path></svg>',
        "arrow.clockwise":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 5v5h-5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path><path d="M20 10a8 8 0 1 0 2 5.3" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path></svg>',
        pencil:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20l4.1-.9L18.3 8.9a1.7 1.7 0 0 0 0-2.4l-.8-.8a1.7 1.7 0 0 0-2.4 0L4.9 15.9 4 20z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M13.6 6.9l3.5 3.5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path></svg>',
        "square.and.pencil":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20l4.1-.9L18.3 8.9a1.7 1.7 0 0 0 0-2.4l-.8-.8a1.7 1.7 0 0 0-2.4 0L4.9 15.9 4 20z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M13.6 6.9l3.5 3.5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path></svg>',
        "doc-on-doc":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5.5h7l3 3V17a1.5 1.5 0 0 1-1.5 1.5H9" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M8 8.5H6.5A1.5 1.5 0 0 0 5 10v8.5A1.5 1.5 0 0 0 6.5 20h7A1.5 1.5 0 0 0 15 18.5V10l-3-3H8z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path></svg>',
        "doc.on.doc":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5.5h7l3 3V17a1.5 1.5 0 0 1-1.5 1.5H9" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M8 8.5H6.5A1.5 1.5 0 0 0 5 10v8.5A1.5 1.5 0 0 0 6.5 20h7A1.5 1.5 0 0 0 15 18.5V10l-3-3H8z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path></svg>',
        "readex.copy.c1":
          '<svg viewBox="0 0 21 21" fill="none" aria-hidden="true"><path d="M13.468 11.1216C13.468 10.4107 13.468 9.91717 13.4367 9.53369C13.4137 9.25191 13.3758 9.0622 13.3244 8.91846L13.2687 8.78858C13.1148 8.48652 12.8803 8.23344 12.593 8.05713L12.466 7.98584C12.308 7.90546 12.0963 7.84854 11.7209 7.81787C11.3374 7.78656 10.8439 7.78662 10.133 7.78662H7.29999C6.58895 7.78662 6.09562 7.78654 5.7121 7.81787C5.43015 7.84091 5.24064 7.87872 5.09686 7.93018L4.96698 7.98584C4.66487 8.13977 4.41184 8.37419 4.23554 8.66162L4.16522 8.78858C4.08477 8.94657 4.02794 9.15811 3.99725 9.53369C3.96594 9.91718 3.96503 10.4107 3.96503 11.1216V13.9546C3.96503 14.6656 3.96592 15.159 3.99725 15.5425C4.02796 15.9182 4.08471 16.1296 4.16522 16.2876L4.23554 16.4136C4.41185 16.7012 4.66472 16.9353 4.96698 17.0894L5.09686 17.146C5.24061 17.1974 5.43024 17.2343 5.7121 17.2573C6.09562 17.2887 6.58895 17.2896 7.29999 17.2896H10.133C10.8439 17.2896 11.3374 17.2886 11.7209 17.2573C12.0965 17.2266 12.308 17.1698 12.466 17.0894L12.593 17.019C12.8804 16.8427 13.1148 16.5897 13.2687 16.2876L13.3244 16.1577C13.3759 16.0139 13.4137 15.8244 13.4367 15.5425C13.468 15.159 13.468 14.6656 13.468 13.9546V11.1216ZM14.798 13.1196C15.2528 13.118 15.6011 13.1147 15.8879 13.0913C16.2634 13.0606 16.475 13.0038 16.633 12.9233L16.759 12.8521C17.0466 12.6757 17.2808 12.4228 17.4348 12.1206L17.4914 11.9907C17.5428 11.847 17.5797 11.6572 17.6027 11.3755C17.634 10.992 17.6349 10.4985 17.6349 9.7876V6.95459C17.6349 6.24355 17.6341 5.75022 17.6027 5.3667C17.5797 5.08484 17.5428 4.89522 17.4914 4.75147L17.4348 4.62158C17.2807 4.31933 17.0466 4.06645 16.759 3.89014L16.633 3.81982C16.475 3.73932 16.2636 3.68256 15.8879 3.65186C15.5044 3.62052 15.011 3.61963 14.3 3.61963H11.467C10.7561 3.61963 10.2626 3.62054 9.87909 3.65186C9.59738 3.67487 9.40759 3.71179 9.26386 3.76318L9.13397 3.81982C8.83175 3.97382 8.57885 4.20802 8.40253 4.49561L8.33124 4.62158C8.25079 4.77957 8.19396 4.99114 8.16327 5.3667C8.13984 5.65352 8.13561 6.00178 8.13397 6.45654H10.133C10.822 6.45654 11.3791 6.4559 11.8293 6.49268C12.2873 6.5301 12.6937 6.6093 13.0705 6.80127L13.2883 6.92334C13.7839 7.22739 14.1878 7.66313 14.4533 8.18408L14.5197 8.32666C14.6642 8.66318 14.7291 9.02433 14.7619 9.42529C14.7987 9.8755 14.798 10.4326 14.798 11.1216V13.1196ZM18.965 9.7876C18.965 10.4766 18.9657 11.0337 18.9289 11.4839C18.8961 11.8848 18.8311 12.246 18.6867 12.5825L18.6203 12.7251C18.3548 13.246 17.9509 13.6818 17.4553 13.9858L17.2365 14.1079C16.8599 14.2998 16.4541 14.3791 15.9963 14.4165C15.6592 14.444 15.2624 14.4481 14.7951 14.4497C14.7935 14.917 14.7894 15.3138 14.7619 15.6509C14.7292 16.0516 14.664 16.4122 14.5197 16.7485L14.4533 16.8911C14.1878 17.4122 13.7841 17.8487 13.2883 18.1528L13.0705 18.2749C12.6937 18.4669 12.2873 18.5461 11.8293 18.5835C11.3791 18.6203 10.822 18.6196 10.133 18.6196H7.29999C6.6109 18.6196 6.05394 18.6203 5.6037 18.5835C5.20305 18.5508 4.84233 18.4855 4.50604 18.3413L4.36347 18.2749C3.84243 18.0094 3.40584 17.6056 3.10175 17.1099L2.97968 16.8911C2.78787 16.5145 2.70849 16.1087 2.67108 15.6509C2.6343 15.2006 2.63495 14.6437 2.63495 13.9546V11.1216C2.63495 10.4326 2.63431 9.8755 2.67108 9.42529C2.7085 8.96729 2.78771 8.56084 2.97968 8.18408L3.10175 7.96631C3.40585 7.47049 3.84235 7.06679 4.36347 6.80127L4.50604 6.73486C4.84236 6.59059 5.20302 6.52542 5.6037 6.49268C5.9405 6.46516 6.33707 6.4601 6.80389 6.4585C6.8055 5.99167 6.81056 5.5951 6.83807 5.2583C6.87549 4.80047 6.95482 4.39471 7.14667 4.01807L7.26874 3.79932C7.5728 3.30371 8.00855 2.89973 8.52948 2.63428L8.67206 2.56787C9.00854 2.42345 9.36978 2.35844 9.77069 2.32568C10.2209 2.28891 10.778 2.28955 11.467 2.28955H14.3C14.9891 2.28955 15.546 2.2889 15.9963 2.32568C16.4541 2.3631 16.8599 2.44247 17.2365 2.63428L17.4553 2.75635C17.951 3.06044 18.3548 3.49703 18.6203 4.01807L18.6867 4.16065C18.8309 4.49694 18.8962 4.85765 18.9289 5.2583C18.9657 5.70854 18.965 6.2655 18.965 6.95459V9.7876Z" fill="currentColor"></path></svg>',
        "readex.check.c1":
          '<svg viewBox="0 0 17 17" fill="none" aria-hidden="true"><path d="M12.8961 3.64101C13.1297 3.41418 13.4984 3.37523 13.7779 3.56581C14.0571 3.75635 14.1554 4.11331 14.0299 4.41347L13.9615 4.53847L7.71151 13.7045C7.59411 13.8767 7.4063 13.9877 7.19881 14.0072C6.99136 14.0267 6.78564 13.9533 6.63826 13.806L2.88826 10.056L2.79842 9.9457C2.6192 9.67407 2.64927 9.30496 2.88826 9.06581C3.12738 8.82669 3.49647 8.79676 3.76815 8.97597L3.8785 9.06581L7.03084 12.2182L12.8053 3.74941L12.8961 3.64101Z" fill="currentColor"></path></svg>',
        "doc.text.magnifyingglass":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6.5 3.5h7l4 4V13" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M13.5 3.5V8h4" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M6.5 7.5V19c0 .8.7 1.5 1.5 1.5h5.2" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path><path d="M9 11h5M9 14h3" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="1.8"></path><circle cx="16.2" cy="16.2" r="3.2" fill="none" stroke="currentColor" stroke-width="2"></circle><path d="M18.7 18.7L21 21" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path></svg>',
        "point.3.connected.trianglepath.dotted":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="4.8" r="2.2" fill="none" stroke="currentColor" stroke-width="2"></circle><circle cx="5.4" cy="17.8" r="2.2" fill="none" stroke="currentColor" stroke-width="2"></circle><circle cx="18.6" cy="17.8" r="2.2" fill="none" stroke="currentColor" stroke-width="2"></circle><path d="M10.9 6.8L6.5 15.8M13.1 6.8l4.4 9M7.7 17.8h8.6" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="1.8" stroke-dasharray="1.2 2.2"></path></svg>',
        "list.bullet.rectangle":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3.5" y="5" width="17" height="14" rx="2.3" fill="none" stroke="currentColor" stroke-width="2"></rect><circle cx="8" cy="10" r="1" fill="currentColor"></circle><circle cx="8" cy="14" r="1" fill="currentColor"></circle><path d="M11 10h5M11 14h5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="1.9"></path></svg>',
        "text.alignleft":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 6h14M5 10h10M5 14h14M5 18h8" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.1"></path></svg>',
        "square.stack.3d.up":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.5l8 4-8 4-8-4 8-4z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M5.2 11l6.8 3.4 6.8-3.4M5.2 14.8l6.8 3.7 6.8-3.7" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2"></path></svg>',
        "gauge.with.dots.needle.33percent":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 15.5a8 8 0 0 1 16 0" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path><circle cx="12" cy="15.5" r="1.5" fill="currentColor"></circle><path d="M12 15.5l-3.5-3" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path><circle cx="7" cy="15" r=".8" fill="currentColor"></circle><circle cx="8.3" cy="10.4" r=".8" fill="currentColor"></circle><circle cx="12" cy="8.8" r=".8" fill="currentColor"></circle><circle cx="15.7" cy="10.4" r=".8" fill="currentColor"></circle><circle cx="17" cy="15" r=".8" fill="currentColor"></circle></svg>',
        checkmark:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.2 4.2L19 7" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.4"></path></svg>',
        xmark:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 7l10 10M17 7L7 17" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.4"></path></svg>',
        "pause.circle":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"></circle><path d="M9.5 8.2v7.6M14.5 8.2v7.6" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.2"></path></svg>',
        "arrow.triangle.branch":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 19V5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.1"></path><path d="M6 9c5.5 0 8-3.5 11-3.5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.1"></path><path d="M6 15c5.5 0 8 3.5 11 3.5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.1"></path><path d="M16 2.8l3 2.7-3 2.7" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path><path d="M16 15.8l3 2.7-3 2.7" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path></svg>',
        "octicons.git-branch-24":
          '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M15 4.75a3.25 3.25 0 1 1 6.5 0 3.25 3.25 0 0 1-6.5 0ZM2.5 19.25a3.25 3.25 0 1 1 6.5 0 3.25 3.25 0 0 1-6.5 0Zm0-14.5a3.25 3.25 0 1 1 6.5 0 3.25 3.25 0 0 1-6.5 0ZM5.75 6.5a1.75 1.75 0 1 0-.001-3.501A1.75 1.75 0 0 0 5.75 6.5Zm0 14.5a1.75 1.75 0 1 0-.001-3.501A1.75 1.75 0 0 0 5.75 21Zm12.5-14.5a1.75 1.75 0 1 0-.001-3.501A1.75 1.75 0 0 0 18.25 6.5Z"></path><path d="M5.75 16.75A.75.75 0 0 1 5 16V8a.75.75 0 0 1 1.5 0v8a.75.75 0 0 1-.75.75Z"></path><path d="M17.5 8.75v-1H19v1a3.75 3.75 0 0 1-3.75 3.75h-7a1.75 1.75 0 0 0-1.75 1.75H5A3.25 3.25 0 0 1 8.25 11h7a2.25 2.25 0 0 0 2.25-2.25Z"></path></svg>',
        "readex.fork.c1":
          '<svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><g transform="translate(0.7 0)"><path d="M15.8 11.535c.367 0 .665.298.665.665v5a.665.665 0 0 1-.665.665h-5a.665.665 0 1 1 0-1.33h3.394l-3.565-3.564a.666.666 0 0 1 .942-.942l3.564 3.565V12.2c0-.367.298-.665.665-.665Zm0-9.4c.367 0 .665.298.665.665v5a.665.665 0 0 1-1.33 0V4.405l-5.128 5.128c-.323.324-.558.565-.842.74a2.668 2.668 0 0 1-.771.319c-.324.078-.662.073-1.12.073H1.93a.665.665 0 1 1 0-1.33h5.345c.52 0 .673-.005.809-.037.136-.033.266-.086.385-.16.12-.072.23-.177.598-.545l5.128-5.128H10.8a.665.665 0 0 1 0-1.33h5Z" fill="currentColor"></path></g></svg>',
        trash:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 7h14" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path><path d="M9 7V5.8c0-.7.6-1.3 1.3-1.3h3.4c.7 0 1.3.6 1.3 1.3V7" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2"></path><path d="M8 7l.7 11.1c.1.8.7 1.4 1.5 1.4h3.6c.8 0 1.4-.6 1.5-1.4L16 7" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path></svg>',
        "film.stack":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6.5" y="4.5" width="11" height="15" rx="2" fill="none" stroke="currentColor" stroke-width="2"></rect><path d="M9.5 4.5v15M14.5 4.5v15M6.5 8h-3M6.5 12h-3M6.5 16h-3M20.5 8h-3M20.5 12h-3M20.5 16h-3" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="1.7"></path></svg>',
        "photo.on.rectangle.angled":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7.2 5.2l9.8-1.7c1-.2 1.9.5 2.1 1.5l1.5 8.6c.2 1-.5 1.9-1.5 2.1l-1.2.2" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2"></path><rect x="4.2" y="7.4" width="13.4" height="10.8" rx="2" fill="none" stroke="currentColor" stroke-width="2"></rect><circle cx="8.3" cy="11.3" r="1.1" fill="currentColor"></circle><path d="M6.2 16l3-3.1 2.3 2.2 1.7-1.8 2.3 2.7" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8"></path></svg>',
        "captions.bubble":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5.5 5.5h13A2.5 2.5 0 0 1 21 8v6.5a2.5 2.5 0 0 1-2.5 2.5h-6.3L8 20v-3H5.5A2.5 2.5 0 0 1 3 14.5V8a2.5 2.5 0 0 1 2.5-2.5z" fill="none" stroke="currentColor" stroke-linejoin="round" stroke-width="2"></path><path d="M7.2 11h3.1M13.6 11h3.2M7.2 14h5.2M15 14h1.8" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="1.8"></path></svg>',
        waveform:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 14v-4M8 18V6M12 21V3M16 18V6M20 14v-4" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.2"></path></svg>',
        "arrow.down.circle":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"></circle><path d="M12 6.5v9M8.5 12.5L12 16l3.5-3.5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path></svg>',
        "arrow.down.circle.fill":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9.2" fill="currentColor"></circle><path d="M12 6.6v8.1M8.7 11.9L12 15.2l3.3-3.3" fill="none" stroke="white" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path></svg>',
        "checkmark.circle.fill":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9.2" fill="currentColor"></circle><path d="M7.6 12.2l2.8 2.8 6-6.2" fill="none" stroke="white" stroke-linecap="round" stroke-linejoin="round" stroke-width="2.1"></path></svg>',
        "exclamationmark.triangle.fill":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11.2 4.3a.95.95 0 0 1 1.6 0l8.2 14.2a.95.95 0 0 1-.8 1.4H3.8a.95.95 0 0 1-.8-1.4l8.2-14.2z" fill="currentColor"></path><path d="M12 8.8v4.8M12 16.9h.01" fill="none" stroke="white" stroke-linecap="round" stroke-width="2.1"></path></svg>',
        "wand.and.stars":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 19L17.5 6.5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.2"></path><path d="M14.8 6.2l3 3" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2.2"></path><path d="M7.5 6.2l.7 1.7 1.7.7-1.7.7-.7 1.7-.7-1.7-1.7-.7 1.7-.7.7-1.7zM18.8 14l.5 1.3 1.3.5-1.3.5-.5 1.3-.5-1.3-1.3-.5 1.3-.5.5-1.3zM4 12.5l.4 1 .9.4-.9.4-.4 1-.4-1-.9-.4.9-.4.4-1z" fill="currentColor"></path></svg>',
        cpu:
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="7" width="10" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="2"></rect><path d="M9 1.5v3M15 1.5v3M9 19.5v3M15 19.5v3M1.5 9h3M1.5 15h3M19.5 9h3M19.5 15h3" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="2"></path></svg>',
        "spinner-legacy":
          '<svg viewBox="0 0 24 24" aria-hidden="true"><g fill="currentColor"><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="1"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.92" transform="rotate(30 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.84" transform="rotate(60 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.76" transform="rotate(90 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.68" transform="rotate(120 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.60" transform="rotate(150 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.52" transform="rotate(180 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.44" transform="rotate(210 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.36" transform="rotate(240 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.28" transform="rotate(270 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.20" transform="rotate(300 12 12)"></rect><rect x="11" y="1.75" width="2" height="5.25" rx="1" opacity="0.12" transform="rotate(330 12 12)"></rect></g></svg>'
      };
      return svgByName[name] || "";
    }

    function appendIcon(container, name, className) {
      const iconMarkup = makeIcon(name);
      if (!iconMarkup) {
        return null;
      }
      const wrapper = document.createElement("span");
      if (className) {
        wrapper.className = className;
      }
      wrapper.innerHTML = iconMarkup;
      const node = wrapper.firstElementChild;
      if (!node) {
        return null;
      }
      container.appendChild(node);
      return node;
    }

    function isReadexDerivedConversationNotice(text) {
      return trimmed(text) === "从对话中派生";
    }

    const readexDerivedConversationNoticeIconName = "octicons.git-branch-24";

    function syncReadexDerivedBranchNoticeIcon(element, key, text) {
      const label = element.querySelector(".message-branch-notice-label");
      if (!label) {
        return;
      }
      let center = label.closest(".message-branch-notice-center");
      if (!center) {
        center = document.createElement("span");
        center.className = "message-branch-notice-center";
        const existingIcon = element.querySelector(".message-branch-notice-icon");
        if (label.parentElement === element) {
          element.insertBefore(center, label);
        } else {
          element.appendChild(center);
        }
        if (existingIcon) {
          center.appendChild(existingIcon);
        }
        center.appendChild(label);
      }
      let icon = element.querySelector(".message-branch-notice-icon");
      if (!isReadexDerivedConversationNotice(text)) {
        if (icon) {
          icon.remove();
        }
        element.style.removeProperty("--readex-branch-notice-accent");
        return;
      }
      if (!icon) {
        icon = document.createElement("span");
        icon.className = "message-branch-notice-icon";
        icon.setAttribute("aria-hidden", "true");
        center.insertBefore(icon, label);
      }
      if (icon.dataset.iconName !== readexDerivedConversationNoticeIconName) {
        icon.innerHTML = makeIcon(readexDerivedConversationNoticeIconName);
        icon.dataset.iconName = readexDerivedConversationNoticeIconName;
      }
      element.style.setProperty("--readex-branch-notice-accent", readexAccentColor(`${key}:${text}`));
    }

    function configureBranchNotice(element, key, text) {
      element.className = "message-branch-notice";
      element.dataset.branchNoticeKey = key;
      element.setAttribute("aria-label", text);
      element.__chatTranscriptSignature = text;
      element.classList.toggle("readex-derived-conversation", isReadexDerivedConversationNotice(text));
    }

    function renderBranchNotice(key, text) {
      const notice = document.createElement("div");
      configureBranchNotice(notice, key, text);

      const leadingLine = document.createElement("span");
      leadingLine.className = "message-branch-notice-line";
      leadingLine.setAttribute("aria-hidden", "true");

      const label = document.createElement("span");
      label.className = "message-branch-notice-label";
      label.textContent = text;

      const center = document.createElement("span");
      center.className = "message-branch-notice-center";
      center.appendChild(label);

      const trailingLine = document.createElement("span");
      trailingLine.className = "message-branch-notice-line";
      trailingLine.setAttribute("aria-hidden", "true");

      notice.append(leadingLine, center, trailingLine);
      syncReadexDerivedBranchNoticeIcon(notice, key, text);
      return notice;
    }

    function patchBranchNotice(notice, key, text) {
      if (!notice || notice.__chatTranscriptSignature !== text) {
        return renderBranchNotice(key, text);
      }
      configureBranchNotice(notice, key, text);
      const label = notice.querySelector(".message-branch-notice-label");
      if (label && label.textContent !== text && !label.classList.contains("readex-tool-shimmer")) {
        label.textContent = text;
      }
      syncReadexDerivedBranchNoticeIcon(notice, key, text);
      return notice;
    }

    function formatThinkingSeconds(milliseconds) {
      const normalizedMilliseconds = Math.max(100, Number(milliseconds) || 0);
      return (normalizedMilliseconds / 1000).toFixed(1);
    }

    function hostnameForReference(reference) {
      const rawURL = trimmed(reference?.url);
      if (!rawURL) {
        return "";
      }

      const candidates = rawURL.includes("://") ? [rawURL] : [`https://${rawURL}`, rawURL];
      for (const candidate of candidates) {
        try {
          const url = new URL(candidate);
          const host = (url.host || "").trim();
          if (host) {
            return host.startsWith("www.") ? host.slice(4) : host;
          }
        } catch (error) {
        }
      }

      return rawURL.split("/")[0]?.trim() || "";
    }

    function displayTitleForReference(reference) {
      const title = trimmed(reference.title);
      if (title) {
        return title;
      }
      const hostname = hostnameForReference(reference);
      if (hostname) {
        return hostname;
      }
      return trimmed(reference.url);
    }

    function hashString(value) {
      let hash = 0;
      for (let index = 0; index < value.length; index += 1) {
        hash = (hash * 31 + value.charCodeAt(index)) >>> 0;
      }
      return hash;
    }

    function avatarPalette(reference) {
      const backgrounds = ["#e3edff", "#ebf2e6", "#fcecdf", "#f4e5f4", "#e5f2f2"];
      const foregrounds = ["#3861c2", "#307a57", "#bd6f1a", "#8f43a8", "#257480"];
      const seed = displayTitleForReference(reference) || reference.url || "•";
      const paletteIndex = hashString(seed) % backgrounds.length;
      return {
        background: backgrounds[paletteIndex],
        foreground: foregrounds[paletteIndex]
      };
    }

    function avatarTextForReference(reference) {
      const seed = displayTitleForReference(reference) || reference.url || "•";
      return Array.from(seed)[0] || "•";
    }

    function normalizedSearchProviderKind(reference) {
      const rawValue = trimmed(reference?.searchProviderKind).toLowerCase();
      return rawValue || "";
    }

    function searchProviderIconResourceName(reference) {
      switch (normalizedSearchProviderKind(reference)) {
        case "local-google":
          return "google";
        case "local-bing":
          return "bing";
        case "local-baidu":
          return "baidu";
        default:
          return "";
      }
    }

    function searchProviderIconCandidates(reference) {
      const resourceName = searchProviderIconResourceName(reference);
      if (!resourceName) {
        return [];
      }
      return [
        `SearchProviderIcons/${resourceName}.svg`,
        `Resources/SearchProviderIcons/${resourceName}.svg`,
        `${resourceName}.svg`
      ];
    }

    function faviconURLForReference(reference) {
      const hostname = hostnameForReference(reference);
      if (!hostname) {
        return "";
      }
      const params = new URLSearchParams({
        domain_url: `https://${hostname}`,
        sz: "128"
      });
      return `https://www.google.com/s2/favicons?${params.toString()}`;
    }

    function applyFallbackReferenceAvatar(avatar, reference) {
      if (!avatar) {
        return;
      }

      avatar.classList.remove("has-provider-icon");
      avatar.replaceChildren();
      avatar.textContent = avatarTextForReference(reference);
      const palette = avatarPalette(reference);
      avatar.style.background = palette.background;
      avatar.style.color = palette.foreground;
    }

    function populateReferenceAvatar(avatar, reference) {
      if (!avatar) {
        return;
      }

      const imageCandidates = [
        faviconURLForReference(reference),
        ...searchProviderIconCandidates(reference)
      ].filter(Boolean);

      if (imageCandidates.length) {
        avatar.classList.add("has-provider-icon");
        avatar.replaceChildren();
        avatar.style.background = "rgba(255, 255, 255, 0.92)";
        avatar.style.color = "inherit";

        const image = document.createElement("img");
        image.alt = "";
        image.setAttribute("aria-hidden", "true");

        let candidateIndex = 0;
        const tryNextCandidate = () => {
          if (candidateIndex >= imageCandidates.length) {
            applyFallbackReferenceAvatar(avatar, reference);
            return;
          }
          image.src = imageCandidates[candidateIndex];
          candidateIndex += 1;
        };

        image.addEventListener("error", tryNextCandidate);
        avatar.appendChild(image);
        tryNextCandidate();
        return;
      }

      applyFallbackReferenceAvatar(avatar, reference);
    }

    return Object.freeze({
      makeIcon,
      appendIcon,
      readexAccentColor,
      renderBranchNotice,
      patchBranchNotice,
      formatThinkingSeconds,
      hostnameForReference,
      displayTitleForReference,
      populateReferenceAvatar
    });
  };
})();
