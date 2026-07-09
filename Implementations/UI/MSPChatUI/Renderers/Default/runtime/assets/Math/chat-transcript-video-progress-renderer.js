(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript video progress renderer dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptVideoProgressRendererFactory = function createChatTranscriptVideoProgressRenderer(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const makeIcon = requiredFunction(dependencies, "makeIcon");
    const animationStateByKey = new Map();

    function normalizedProgress(block) {
      const raw = Number(block?.progress);
      if (Number.isFinite(raw)) {
        return Math.min(Math.max(raw, 0), 1);
      }
      const status = trimmed(block?.status).toLowerCase();
      if (status === "completed" || status === "success") {
        return 1;
      }
      return 0;
    }

    function normalizedStatus(block) {
      const status = trimmed(block?.status).toLowerCase();
      if (status === "failed" || trimmed(block?.phase).toLowerCase() === "failed") {
        return "failed";
      }
      if (status === "partial" || status === "partial_success" || status === "warning" || status === "completed_with_warnings") {
        return "partial";
      }
      if (status === "completed" || status === "success" || trimmed(block?.phase).toLowerCase() === "completed") {
        return "completed";
      }
      if (status === "paused" || status === "pause") {
        return "paused";
      }
      if (status === "interrupted" || status === "cancelled" || status === "canceled" || status === "stopped") {
        return "interrupted";
      }
      return "processing";
    }

    function iconName(status) {
      if (status === "failed") {
        return "exclamationmark.triangle.fill";
      }
      if (status === "completed") {
        return "checkmark.circle.fill";
      }
      if (status === "partial") {
        return "exclamationmark.triangle.fill";
      }
      if (status === "paused" || status === "interrupted") {
        return "pause.circle";
      }
      return "arrow.down.circle.fill";
    }

    function animationKey(source, fallbackKey) {
      return trimmed(source?.sourceBlockId)
        || trimmed(source?.sourceBlockID)
        || trimmed(source?.id)
        || trimmed(fallbackKey)
        || "inline";
    }

    function integerPart(value, minimum) {
      const number = Math.trunc(Number(value));
      return Number.isFinite(number) && number >= minimum ? number : null;
    }

    function progressSubjectKey(source) {
      const subject = subtitleParts(source).subject;
      return trimmed(subject).replace(/\s+/g, " ");
    }

    function progressItemAnimationKey(source, fallbackKey) {
      const baseKey = animationKey(source, fallbackKey);
      const currentIndex = integerPart(source?.batchCurrentItemIndex, 1);
      if (currentIndex != null) {
        return `${baseKey}:item:${currentIndex}`;
      }
      const completedCount = integerPart(source?.batchCompletedItemCount, 0);
      if (completedCount != null) {
        const subjectKey = progressSubjectKey(source);
        return subjectKey
          ? `${baseKey}:item-after:${completedCount}:${subjectKey}`
          : `${baseKey}:item-after:${completedCount}`;
      }
      return `${baseKey}:item`;
    }

    function overallAnimationKey(source, fallbackKey) {
      return `${animationKey(source, fallbackKey)}:overall`;
    }

    function lineLooksLikeURL(line) {
      const text = trimmed(line);
      return /^https?:\/\//i.test(text) || /^www\./i.test(text);
    }

    function visibleSubtitleLines(block) {
      return trimmed(block?.subtitleText)
        .split(/\r?\n/)
        .map((line) => trimmed(line))
        .filter(Boolean)
        .filter((line) => !lineLooksLikeURL(line));
    }

    function subtitleParts(block) {
      const lines = visibleSubtitleLines(block);
      if (!lines.length) {
        return { subject: "", metadataLines: [] };
      }
      const firstLine = lines[0];
      const hasSubject = firstLine.startsWith("《") && firstLine.endsWith("》");
      return {
        subject: hasSubject ? firstLine : "",
        metadataLines: hasSubject ? lines.slice(1) : lines
      };
    }

    function headerTitleLooksLikeDetail(value) {
      const text = trimmed(value);
      if (!text) {
        return false;
      }
      return lineLooksLikeURL(text)
        || text.includes("\n")
        || text.includes(" / ")
        || /\/s\b/i.test(text)
        || /ETA\b/i.test(text)
        || text.includes("剩余 ")
        || text.includes("[download]")
        || text.includes("Destination:");
    }

    function defaultTitle(status) {
      if (status === "completed") {
        return "已下载完成";
      }
      if (status === "failed") {
        return "下载失败";
      }
      if (status === "partial") {
        return "部分下载完成";
      }
      if (status === "paused") {
        return "需要选择下载格式";
      }
      if (status === "interrupted") {
        return "已取消下载";
      }
      return "正在下载";
    }

    function headerTitle(block, status, usesItemList = false) {
      if (usesItemList) {
        if (status === "processing") {
          return "正在下载视频";
        }
        return defaultTitle(status);
      }
      const candidate = trimmed(block?.text);
      if (candidate && !headerTitleLooksLikeDetail(candidate)) {
        return candidate;
      }
      return defaultTitle(status);
    }

    function summaryPartIsOverallBatch(value) {
      return /^已下载：\d+(?:\s*\/\s*\d+)?$/.test(trimmed(value));
    }

    function detailText(block, status) {
      const rawDetail = trimmed(block?.detailText);
      const lines = rawDetail
        .split(/\r?\n/)
        .map((line) => trimmed(line))
        .filter(Boolean)
        .filter((line) => !lineLooksLikeURL(line))
        .filter((line) => !/^已保存到\s+/.test(line))
        .filter((line) => line !== "Completed" && line !== "Download completed.");
      if (lines.length) {
        return lines.join("\n");
      }

      const summaryParts = Array.isArray(block?.summaryParts)
        ? block.summaryParts.map((part) => trimmed(part)).filter(Boolean)
        : [];
      const visibleSummaryParts = summaryParts
        .filter((part) => !lineLooksLikeURL(part))
        .filter((part) => !summaryPartIsOverallBatch(part));
      if (visibleSummaryParts.length) {
        return visibleSummaryParts.join(" · ");
      }

      if (status === "processing") {
        const phaseTitle = trimmed(block?.phaseTitle);
        if (phaseTitle && phaseTitle !== trimmed(block?.text) && !headerTitleLooksLikeDetail(phaseTitle)) {
          return phaseTitle;
        }
      }
      return "";
    }

    function now() {
      return (typeof performance !== "undefined" && typeof performance.now === "function")
        ? performance.now()
        : Date.now();
    }

    function clampProgress(value) {
      const numeric = Number(value);
      return Number.isFinite(numeric) ? Math.min(Math.max(numeric, 0), 1) : 0;
    }

    function estimatedProgress(source, fallbackProgress, status, nowMilliseconds = Date.now()) {
      const base = clampProgress(fallbackProgress);
      if (status !== "processing") {
        return base;
      }

      const updatedAt = Number(source?.progressUpdatedAtMilliseconds);
      const rate = Number(source?.progressRatePerSecond);
      if (!Number.isFinite(updatedAt) || updatedAt <= 0 || !Number.isFinite(rate) || rate <= 0) {
        return base;
      }

      const elapsedSeconds = Math.min(Math.max((nowMilliseconds - updatedAt) / 1000, 0), 20);
      if (elapsedSeconds <= 0) {
        return base;
      }

      return Math.min(Math.max(base, base + elapsedSeconds * rate), 0.995);
    }

    function canPredict(source, status) {
      if (status !== "processing") {
        return false;
      }
      const updatedAt = Number(source?.progressUpdatedAtMilliseconds);
      const rate = Number(source?.progressRatePerSecond);
      return Number.isFinite(updatedAt) && updatedAt > 0 && Number.isFinite(rate) && rate > 0;
    }

    function predictionIsFresh(source) {
      const updatedAt = Number(source?.progressUpdatedAtMilliseconds);
      return Number.isFinite(updatedAt) && updatedAt > 0 && Date.now() - updatedAt < 20000;
    }

    function setFill(fill, progress) {
      if (!fill) {
        return;
      }
      const value = clampProgress(progress);
      const scale = value <= 0 ? 0.0125 : Math.max(value, 0.0125);
      fill.style.removeProperty("width");
      fill.style.setProperty("--readex-video-progress-scale", scale.toFixed(4));
    }

    function percentLabel(progress, status) {
      const value = clampProgress(progress);
      if (status === "completed") {
        return "100%";
      }
      if (status === "partial") {
        return "部分";
      }
      if (value > 0 && value < 0.01) {
        return "<1%";
      }
      return `${Math.round(value * 100)}%`;
    }

    function setPercentLabel(label, progress, status) {
      if (label) {
        label.textContent = percentLabel(progress, status);
      }
    }

    function batchProgress(block) {
      const totalCount = block?.batchTotalItemCount == null
        ? NaN
        : Math.trunc(Number(block.batchTotalItemCount));
      const hasTotalCount = Number.isFinite(totalCount) && totalCount > 1;
      const rawCompletedCount = block?.batchCompletedItemCount == null
        ? NaN
        : Math.trunc(Number(block.batchCompletedItemCount));
      if (!hasTotalCount && (!Number.isFinite(rawCompletedCount) || rawCompletedCount <= 0)) {
        return null;
      }
      if (!hasTotalCount && rawCompletedCount <= 1) {
        return null;
      }
      const completedCount = hasTotalCount
        ? (Number.isFinite(rawCompletedCount)
          ? Math.min(Math.max(rawCompletedCount, 0), totalCount)
          : 0)
        : Math.max(rawCompletedCount, 0);
      if (!hasTotalCount) {
        return {
          currentIndex: null,
          completedCount,
          totalCount: null,
          progress: null
        };
      }
      const clampedCompletedCount = Number.isFinite(rawCompletedCount)
        ? Math.min(Math.max(rawCompletedCount, 0), totalCount)
        : 0;
      const rawCurrentIndex = block?.batchCurrentItemIndex == null
        ? NaN
        : Math.trunc(Number(block.batchCurrentItemIndex));
      const currentIndex = Number.isFinite(rawCurrentIndex)
        ? Math.min(Math.max(rawCurrentIndex, 1), totalCount)
        : null;
      const rawProgress = block?.batchProgress == null
        ? NaN
        : Number(block.batchProgress);
      const progress = Number.isFinite(rawProgress)
        ? clampProgress(rawProgress)
        : clampProgress(clampedCompletedCount / totalCount);
      return {
        currentIndex,
        completedCount: clampedCompletedCount,
        totalCount,
        progress
      };
    }

    function monotonicProgressTarget(target, previousDisplayed, status) {
      const value = clampProgress(target);
      if (status === "completed") {
        return 1;
      }
      return Number.isFinite(previousDisplayed)
        ? Math.max(value, clampProgress(previousDisplayed))
        : value;
    }

    function monotonicStoredProgress(key, target, status) {
      const stateKey = trimmed(key);
      const existing = stateKey ? animationStateByKey.get(stateKey) : null;
      const previousDisplayed = Number(existing?.displayedProgress);
      const value = monotonicProgressTarget(target, previousDisplayed, status);
      if (stateKey) {
        rememberState(stateKey, {
          displayedProgress: value,
          targetProgress: value,
          frameID: null,
          token: existing?.token || 0
        });
      }
      return value;
    }

    function appendBatchProgress(root, batch, key, status) {
      if (!root || !batch) {
        return;
      }
      const container = document.createElement("div");
      container.className = "readex-video-progress-overall";

      const label = document.createElement("div");
      label.className = "readex-video-progress-overall-label";
      label.textContent = batch.totalCount
        ? `已下载：${batch.completedCount}/${batch.totalCount}`
        : `已下载：${batch.completedCount}`;
      container.appendChild(label);

      if (batch.totalCount) {
        const track = document.createElement("div");
        track.className = "readex-video-progress-track readex-video-progress-overall-track";
        const fill = document.createElement("div");
        fill.className = "readex-video-progress-fill readex-video-progress-overall-fill";
        setFill(fill, monotonicStoredProgress(key, batch.progress, status));
        track.appendChild(fill);
        container.appendChild(track);
      }

      root.appendChild(container);
    }

    function prefersReducedMotion() {
      return Boolean(
        typeof window !== "undefined"
        && typeof window.matchMedia === "function"
        && window.matchMedia("(prefers-reduced-motion: reduce)").matches
      );
    }

    function rememberState(key, state) {
      if (!key) {
        return;
      }
      animationStateByKey.set(key, state);
      if (animationStateByKey.size <= 80) {
        return;
      }
      const firstKey = animationStateByKey.keys().next().value;
      if (firstKey) {
        animationStateByKey.delete(firstKey);
      }
    }

    function animateFill(fill, key, targetProgress, status, source, label = null) {
      const predicts = canPredict(source, status);
      const stateKey = trimmed(key);
      const existing = stateKey ? animationStateByKey.get(stateKey) : null;
      const previousDisplayed = Number(existing?.displayedProgress);
      const rawTarget = estimatedProgress(source, targetProgress, status);
      const start = Number.isFinite(previousDisplayed)
        ? clampProgress(previousDisplayed)
        : rawTarget;
      const target = monotonicProgressTarget(rawTarget, previousDisplayed, status);

      if (
        !stateKey
        || status !== "processing"
        || target <= start
        || target - start < 0.003
        || typeof window === "undefined"
        || typeof window.requestAnimationFrame !== "function"
      ) {
        if (existing?.frameID && typeof window !== "undefined" && typeof window.cancelAnimationFrame === "function") {
          window.cancelAnimationFrame(existing.frameID);
        }
        setFill(fill, target);
        setPercentLabel(label, target, status);
        rememberState(stateKey, {
          displayedProgress: target,
          targetProgress: target,
          frameID: null,
          token: (existing?.token || 0) + 1
        });
        if (
          stateKey
          && predicts
          && !prefersReducedMotion()
          && typeof window !== "undefined"
          && typeof window.requestAnimationFrame === "function"
        ) {
          const token = (existing?.token || 0) + 2;
          const state = {
            displayedProgress: target,
            targetProgress: target,
            frameID: null,
            token
          };
          rememberState(stateKey, state);
          const step = () => {
            const current = animationStateByKey.get(stateKey);
            if (!current || current.token !== token || !fill.isConnected) {
              return;
            }
            const displayed = Math.max(
              current.displayedProgress,
              estimatedProgress(source, targetProgress, status)
            );
            current.displayedProgress = displayed;
            setFill(fill, displayed);
            setPercentLabel(label, displayed, status);
            if (displayed < 0.995 && predictionIsFresh(source)) {
              current.frameID = window.requestAnimationFrame(step);
            } else {
              current.frameID = null;
            }
          };
          state.frameID = window.requestAnimationFrame(step);
        }
        return;
      }

      if (prefersReducedMotion()) {
        setFill(fill, target);
        setPercentLabel(label, target, status);
        rememberState(stateKey, {
          displayedProgress: target,
          targetProgress: target,
          frameID: null,
          token: (existing?.token || 0) + 1
        });
        return;
      }

      if (existing?.frameID && typeof window.cancelAnimationFrame === "function") {
        window.cancelAnimationFrame(existing.frameID);
      }

      const token = (existing?.token || 0) + 1;
      const startedAt = now();
      const delta = target - start;
      const duration = Math.min(1400, Math.max(420, delta * 2600));
      const state = {
        displayedProgress: start,
        targetProgress: target,
        frameID: null,
        token
      };
      rememberState(stateKey, state);
      setFill(fill, start);
      setPercentLabel(label, start, status);

      const step = (timestamp) => {
        const current = animationStateByKey.get(stateKey);
        if (!current || current.token !== token) {
          return;
        }
        if (!fill.isConnected) {
          current.frameID = null;
          return;
        }
        const elapsed = Math.max(0, timestamp - startedAt);
        const unit = Math.min(elapsed / duration, 1);
        const eased = 1 - Math.pow(1 - unit, 3);
        const animated = start + delta * eased;
        const predicted = predicts
          ? estimatedProgress(source, targetProgress, status)
          : animated;
        const displayed = Math.max(animated, predicted);
        current.displayedProgress = displayed;
        setFill(fill, displayed);
        setPercentLabel(label, displayed, status);
        if (unit < 1 || (predicts && displayed < 0.995 && predictionIsFresh(source))) {
          current.frameID = window.requestAnimationFrame(step);
        } else {
          const finalProgress = Math.max(target, current.displayedProgress);
          current.displayedProgress = finalProgress;
          current.targetProgress = target;
          current.frameID = null;
          setFill(fill, finalProgress);
          setPercentLabel(label, finalProgress, status);
        }
      };

      state.frameID = window.requestAnimationFrame(step);
    }

    function appendDetailLines(detail, value) {
      const lines = trimmed(value)
        .split(/\r?\n/)
        .map((line) => trimmed(line))
        .filter(Boolean);
      if (!lines.length) {
        detail.textContent = trimmed(value);
        return;
      }
      lines.forEach((line) => {
        const row = document.createElement("div");
        row.className = "readex-video-progress-detail-line";
        row.textContent = line;
        detail.appendChild(row);
      });
    }

    function progressItems(block) {
      const items = Array.isArray(block?.items)
        ? block.items
        : (Array.isArray(block?.childItems) ? block.childItems : []);
      return items
        .map((item, index) => {
          const text = trimmed(item?.text);
          const detail = trimmed(item?.detailText);
          const subtitle = trimmed(item?.subtitleText);
          if (!text && !detail && !subtitle) {
            return null;
          }
          return {
            ...item,
            id: trimmed(item?.id) || trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID) || `item:${index}`,
            sourceBlockId: trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID) || trimmed(item?.id) || `item:${index}`,
            text,
            detailText: detail,
            subtitleText: subtitle,
            summaryParts: Array.isArray(item?.summaryParts) ? item.summaryParts : []
          };
        })
        .filter(Boolean);
    }

    function appendVideoSource(root, source) {
      const parts = subtitleParts(source);
      if (!parts.subject && !parts.metadataLines.length) {
        return false;
      }
      const sourceNode = document.createElement("div");
      sourceNode.className = "readex-video-progress-source";
      if (parts.subject) {
        const subject = document.createElement("div");
        subject.className = "readex-video-progress-subject";
        subject.textContent = parts.subject;
        sourceNode.appendChild(subject);
      }
      parts.metadataLines.forEach((line) => {
        const metadata = document.createElement("div");
        metadata.className = "readex-video-progress-subtitle";
        metadata.textContent = line;
        sourceNode.appendChild(metadata);
      });
      root.appendChild(sourceNode);
      return true;
    }

    function appendSingleProgressBody(root, source, status, progressAnimationKey, label) {
      appendVideoSource(root, source);

      const track = document.createElement("div");
      track.className = "readex-video-progress-track";
      const fill = document.createElement("div");
      fill.className = "readex-video-progress-fill";
      animateFill(fill, progressAnimationKey, normalizedProgress(source), status, source, label);
      track.appendChild(fill);
      root.appendChild(track);

      const details = detailText(source, status);
      if (details) {
        const detail = document.createElement("div");
        detail.className = "readex-video-progress-detail";
        appendDetailLines(detail, details);
        root.appendChild(detail);
      }
    }

    function appendProgressItemList(root, block, items, blockKey) {
      if (!items.length) {
        return false;
      }
      const list = document.createElement("div");
      list.className = "readex-video-progress-items";

      items.forEach((item) => {
        const itemStatus = normalizedStatus(item);
        const progress = estimatedProgress(
          item,
          normalizedProgress(item),
          itemStatus
        );
        const itemKey = `${animationKey(block, blockKey)}:active:${trimmed(item.sourceBlockId) || trimmed(item.id)}`;
        const row = document.createElement("div");
        row.className = `readex-video-progress-item is-${itemStatus}`;

        const header = document.createElement("div");
        header.className = "readex-video-progress-item-header";
        const titleWrap = document.createElement("div");
        titleWrap.className = "readex-video-progress-item-title-wrap";
        const parts = subtitleParts(item);
        const title = document.createElement("div");
        title.className = "readex-video-progress-item-title";
        title.textContent = parts.subject || trimmed(item.text) || defaultTitle(itemStatus);
        titleWrap.appendChild(title);
        parts.metadataLines.forEach((line) => {
          const metadata = document.createElement("div");
          metadata.className = "readex-video-progress-item-subtitle";
          metadata.textContent = line;
          titleWrap.appendChild(metadata);
        });
        header.appendChild(titleWrap);

        const label = document.createElement("div");
        label.className = "readex-video-progress-item-percent";
        label.textContent = percentLabel(progress, itemStatus);
        header.appendChild(label);
        row.appendChild(header);

        const track = document.createElement("div");
        track.className = "readex-video-progress-track readex-video-progress-item-track";
        const fill = document.createElement("div");
        fill.className = "readex-video-progress-fill";
        animateFill(fill, itemKey, normalizedProgress(item), itemStatus, item, label);
        track.appendChild(fill);
        row.appendChild(track);

        const details = detailText(item, itemStatus);
        if (details) {
          const detail = document.createElement("div");
          detail.className = "readex-video-progress-detail readex-video-progress-item-detail";
          appendDetailLines(detail, details);
          row.appendChild(detail);
        }

        list.appendChild(row);
      });

      root.appendChild(list);
      return true;
    }

    function renderReadexVideoProgressBlock(block, blockKey) {
      const status = normalizedStatus(block);
      const progress = estimatedProgress(
        block,
        normalizedProgress(block),
        status
      );
      const batch = batchProgress(block);
      const items = progressItems(block);
      const usesItemList = items.length > 1;
      const progressAnimationKey = progressItemAnimationKey(block, blockKey);
      const root = document.createElement("div");
      root.className = `readex-video-progress-card is-${status}${usesItemList ? " has-progress-items" : ""}`;
      root.setAttribute("role", status === "processing" ? "status" : "group");
      root.dataset.progressKey = progressAnimationKey;

      const header = document.createElement("div");
      header.className = "readex-video-progress-header";

      const icon = document.createElement("span");
      icon.className = "readex-video-progress-icon";
      icon.innerHTML = makeIcon(iconName(status));
      header.appendChild(icon);

      const titleWrap = document.createElement("div");
      titleWrap.className = "readex-video-progress-title-wrap";
      const title = document.createElement("div");
      title.className = "readex-video-progress-title";
      title.textContent = headerTitle(block, status, usesItemList);
      titleWrap.appendChild(title);
      header.appendChild(titleWrap);

      let label = null;
      if (!usesItemList) {
        label = document.createElement("div");
        label.className = "readex-video-progress-percent";
        label.textContent = percentLabel(progress, status);
        header.appendChild(label);
      }
      root.appendChild(header);

      if (!appendProgressItemList(root, block, items, blockKey)) {
        appendSingleProgressBody(root, block, status, progressAnimationKey, label);
      }

      appendBatchProgress(root, batch, overallAnimationKey(block, blockKey), status);
      return root;
    }

    return Object.freeze({
      renderReadexVideoProgressBlock
    });
  };
})();
