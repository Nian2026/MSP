(function() {
  if (window.__chatTranscriptSelectionContextMenuInstalled) {
    return;
  }
  window.__chatTranscriptSelectionContextMenuInstalled = true;

  var selectionContextMenuHandlerName = "__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__";

  function selectionContextMenuHandler() {
    var handlers = window.webkit && window.webkit.messageHandlers;
    if (!handlers) {
      return null;
    }
    var handler = handlers[selectionContextMenuHandlerName];
    return handler && typeof handler.postMessage === 'function' ? handler : null;
  }

  function postSelectionContextMenuPayload(payload) {
    var handler = selectionContextMenuHandler();
    if (!handler) {
      return false;
    }
    handler.postMessage(payload);
    return true;
  }

  function trimmed(text) {
    return String(text || '').trim();
  }

  function cssEscape(value) {
    if (window.CSS && typeof window.CSS.escape === 'function') {
      return window.CSS.escape(String(value || ''));
    }
    return String(value || '').replace(/["\\]/g, '\\$&');
  }

  function selectedText() {
    return window.getSelection ? String(window.getSelection()) : '';
  }

  function normalizedRenderedSegment(text) {
    return String(text || '').replace(/\s+/g, ' ').trim();
  }

  var multiSelectionState = null;
  var multiSelectionDragState = null;
  var multiSelectionUndoStack = [];
  var multiSelectionRedoStack = [];
  var multiSelectionHistoryLimit = 80;
  var multiSelectionMarkAttribute = 'data-chat-transcript-multi-selection-mark';
  var multiSelectionHighlightName = 'chat-transcript-multi-selection';
  var multiSelectionHighlightStyleID = 'chat-transcript-multi-selection-highlight-style';
  var nativeSelectionClearStyleID = 'chat-transcript-native-selection-clear-style';
  var defaultMultiSelectionHighlightColor = { red: 0.55, green: 0.84, blue: 0.47, alpha: 0.34 };
  var multiSelectionHighlightColor = normalizedMultiSelectionHighlightColor(window.__chatTranscriptMultiSelectionHighlightColor);

  function selectedSegmentBoundary(node, article) {
    var element = closestElement(node);
    return element && element.closest
      ? (element.closest('li, p, td, th, pre, blockquote, h1, h2, h3, h4, h5, h6, .thinking-content, [data-block-type="thinking"], [data-block-type="main_text"]') || article)
      : article;
  }

  function childIndexWithinParent(parent, child) {
    if (!parent || !child || child.parentNode !== parent) {
      return -1;
    }
    return Array.prototype.indexOf.call(parent.childNodes || [], child);
  }

  function directChildContainingNode(ancestor, node) {
    if (!ancestor || !node || !ancestor.contains || !ancestor.contains(node)) {
      return null;
    }
    var current = node;
    while (current && current.parentNode !== ancestor) {
      current = current.parentNode;
    }
    return current || null;
  }

  function boundaryRelationToTextNode(container, offset, node) {
    if (!container || !node) {
      return null;
    }

    var length = (node.nodeValue || '').length;
    if (container === node) {
      if (offset <= 0) {
        return -1;
      }
      if (offset >= length) {
        return 1;
      }
      return 0;
    }

    if (container.contains && container.contains(node)) {
      var directChild = directChildContainingNode(container, node);
      var childIndex = childIndexWithinParent(container, directChild);
      if (childIndex >= 0) {
        return childIndex < offset ? 1 : -1;
      }
    }

    if (typeof container.compareDocumentPosition === 'function') {
      var position = container.compareDocumentPosition(node);
      if (position & Node.DOCUMENT_POSITION_FOLLOWING) {
        return -1;
      }
      if (position & Node.DOCUMENT_POSITION_PRECEDING) {
        return 1;
      }
    }

    return null;
  }

  function selectedTextOffsetsForNode(range, node) {
    if (!range || !node || !node.nodeValue) {
      return null;
    }

    var length = node.nodeValue.length;
    if (length <= 0) {
      return null;
    }

    var startRelation = boundaryRelationToTextNode(range.startContainer, range.startOffset, node);
    var endRelation = boundaryRelationToTextNode(range.endContainer, range.endOffset, node);
    if (startRelation === null || endRelation === null) {
      return null;
    }
    if (startRelation >= 1 || endRelation <= -1) {
      return null;
    }

    var startOffset = range.startContainer === node ? range.startOffset : 0;
    var endOffset = range.endContainer === node ? range.endOffset : length;
    startOffset = Math.max(0, Math.min(startOffset, length));
    endOffset = Math.max(0, Math.min(endOffset, length));
    return endOffset > startOffset
      ? { start: startOffset, end: endOffset }
      : null;
  }

  function selectedTextSliceForNode(range, node) {
    var offsets = selectedTextOffsetsForNode(range, node);
    if (!offsets) {
      return '';
    }
    return node.nodeValue.slice(offsets.start, offsets.end);
  }

  function selectedRenderedTextSegments(article, selection) {
    if (!article || !selection || selection.rangeCount <= 0) {
      return [];
    }

    var segments = [];
    var segmentIndexByElement = new Map();
    for (var rangeIndex = 0; rangeIndex < selection.rangeCount; rangeIndex += 1) {
      var range = selection.getRangeAt(rangeIndex);
      var root = range.commonAncestorContainer;
      var walkerRoot = root && root.nodeType === Node.TEXT_NODE ? root.parentNode : root;
      if (!walkerRoot) {
        continue;
      }

      var walker = document.createTreeWalker(walkerRoot, NodeFilter.SHOW_TEXT, {
        acceptNode: function(node) {
          if (!node || !node.nodeValue || !selectedTextOffsetsForNode(range, node)) {
            return NodeFilter.FILTER_REJECT;
          }
          if (!article.contains(node)) {
            return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      });

      var current = walker.nextNode();
      while (current) {
        var text = selectedTextSliceForNode(range, current);
        if (text) {
          var boundary = selectedSegmentBoundary(current, article);
          var existingIndex = segmentIndexByElement.get(boundary);
          if (existingIndex == null) {
            existingIndex = segments.length;
            segmentIndexByElement.set(boundary, existingIndex);
            segments.push('');
          }
          segments[existingIndex] += text;
        }
        current = walker.nextNode();
      }
    }

    var seen = new Set();
    return segments
      .map(normalizedRenderedSegment)
      .filter(function(segment) {
        if (!segment || seen.has(segment)) {
          return false;
        }
        seen.add(segment);
        return true;
      });
  }

  function textNodeCanContributeToRenderedRange(node) {
    var parent = node && node.parentElement;
    if (!parent || !node.nodeValue) {
      return false;
    }
    if (/^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA)$/.test(parent.tagName || '')) {
      return false;
    }
    if (parent.closest && parent.closest('button, textarea, .message-actions, .message-action-row, .message-header, .message-footer, .message-expert-domain-badge, .reference-chip, .code-block-header, .katex-mathml')) {
      return false;
    }
    return true;
  }

  function renderedBlockTextIndex(blockElement) {
    var entries = [];
    var text = '';
    if (!blockElement) {
      return { text: text, entries: entries };
    }

    var walker = document.createTreeWalker(blockElement, NodeFilter.SHOW_TEXT, {
      acceptNode: function(node) {
        return textNodeCanContributeToRenderedRange(node)
          ? NodeFilter.FILTER_ACCEPT
          : NodeFilter.FILTER_REJECT;
      }
    });

    var current = walker.nextNode();
    while (current) {
      var value = current.nodeValue || '';
      entries.push({
        node: current,
        start: text.length,
        end: text.length + value.length
      });
      text += value;
      current = walker.nextNode();
    }

    return { text: text, entries: entries };
  }

  function mergeRenderedTextRanges(ranges) {
    var sorted = ranges
      .filter(function(range) {
        return range && Number.isFinite(range.start) && Number.isFinite(range.end) && range.end > range.start;
      })
      .sort(function(lhs, rhs) {
        if (lhs.start === rhs.start) {
          return lhs.end - rhs.end;
        }
        return lhs.start - rhs.start;
      });

    var merged = [];
    sorted.forEach(function(range) {
      var previous = merged.length ? merged[merged.length - 1] : null;
      if (previous && range.start <= previous.end) {
        previous.end = Math.max(previous.end, range.end);
        return;
      }
      merged.push({ start: range.start, end: range.end });
    });
    return merged;
  }

  function mergeRenderedTextRangePayloads(article, ranges) {
    var byBlock = new Map();
    (ranges || []).forEach(function(range) {
      var blockKey = trimmed(range && range.blockKey);
      var start = finiteSourceOffset(range && range.startUTF16Offset);
      var length = finiteSourceOffset(range && range.utf16Length);
      if (!blockKey || start === null || length === null || length <= 0) {
        return;
      }
      var values = byBlock.get(blockKey);
      if (!values) {
        values = [];
        byBlock.set(blockKey, values);
      }
      values.push({ start: start, end: start + length, selectedText: String(range && range.selectedText || '') });
    });

    var mergedPayloads = [];
    byBlock.forEach(function(values, blockKey) {
      var blockElement = mainTextBlockElementForKey(article, blockKey);
      var blockText = blockElement ? renderedBlockTextIndex(blockElement).text : '';
      mergeRenderedTextRanges(values).forEach(function(range) {
        var selectedText = blockText && range.end <= blockText.length
          ? blockText.slice(range.start, range.end)
          : '';
        if (!trimmed(selectedText)) {
          var fallback = values.find(function(value) {
            return value.start === range.start && value.end === range.end && trimmed(value.selectedText);
          });
          selectedText = fallback ? fallback.selectedText : '';
        }
        mergedPayloads.push({
          blockKey: blockKey,
          startUTF16Offset: range.start,
          utf16Length: range.end - range.start,
          selectedText: selectedText
        });
      });
    });

    return mergedPayloads.sort(function(lhs, rhs) {
      if (lhs.blockKey === rhs.blockKey) {
        return lhs.startUTF16Offset - rhs.startUTF16Offset;
      }
      return lhs.blockKey < rhs.blockKey ? -1 : 1;
    });
  }

  function selectedRenderedTextRangesForBlock(blockElement, selection) {
    var blockKey = trimmed(blockElement && blockElement.dataset && blockElement.dataset.blockKey);
    if (!blockElement || !blockKey || !selection || selection.rangeCount <= 0) {
      return [];
    }

    var index = renderedBlockTextIndex(blockElement);
    if (!index.entries.length || !index.text) {
      return [];
    }

    var ranges = [];
    for (var rangeIndex = 0; rangeIndex < selection.rangeCount; rangeIndex += 1) {
      var range = selection.getRangeAt(rangeIndex);
      if (!rangeTouchesMainTextBlock(range, blockElement)) {
        continue;
      }

      index.entries.forEach(function(entry) {
        var offsets = selectedTextOffsetsForNode(range, entry.node);
        if (!offsets) {
          return;
        }
        ranges.push({
          start: entry.start + offsets.start,
          end: entry.start + offsets.end
        });
      });
    }

    return mergeRenderedTextRanges(ranges).map(function(range) {
      return {
        blockKey: blockKey,
        startUTF16Offset: range.start,
        utf16Length: range.end - range.start,
        selectedText: index.text.slice(range.start, range.end)
      };
    }).filter(function(range) {
      return trimmed(range.selectedText);
    });
  }

  function selectedRenderedTextRanges(article, selection) {
    if (!article || !selection || selection.rangeCount <= 0) {
      return [];
    }

    var ranges = [];
    selectedMainTextBlockElements(article, selection).forEach(function(blockElement) {
      ranges = ranges.concat(selectedRenderedTextRangesForBlock(blockElement, selection));
    });
    return ranges;
  }

  function textRangesOf(haystack, needle) {
    var source = String(haystack || '');
    var target = String(needle || '');
    if (!target) {
      return [];
    }

    var ranges = [];
    var searchStart = 0;
    while (searchStart <= source.length) {
      var index = source.indexOf(target, searchStart);
      if (index < 0) {
        break;
      }
      ranges.push({ start: index, end: index + target.length });
      searchStart = index + Math.max(1, target.length);
    }
    return ranges;
  }

  function renderedRangeContainsCandidate(renderedRange, candidateRange) {
    var start = finiteSourceOffset(renderedRange && renderedRange.startUTF16Offset);
    var length = finiteSourceOffset(renderedRange && renderedRange.utf16Length);
    if (start === null || length === null || length <= 0) {
      return false;
    }
    var end = start + length;
    return candidateRange.start >= start && candidateRange.end <= end;
  }

  function sourceMappingSearchCandidates(text) {
    var raw = String(text || '');
    var normalizedSpaces = raw.replace(/\u00a0/g, ' ');
    var candidates = [];
    var seen = new Set();
    function append(value) {
      var candidate = String(value || '');
      if (!trimmed(candidate) || seen.has(candidate)) {
        return;
      }
      seen.add(candidate);
      candidates.push(candidate);
    }

    append(raw);
    append(trimmed(raw));
    append(normalizedSpaces);
    append(trimmed(normalizedSpaces));
    return candidates;
  }

  function localPromptSourceRangeForRenderedRange(blockText, renderedBlockText, renderedRange) {
    var source = String(blockText || '');
    var rendered = String(renderedBlockText || '');
    var renderedStart = finiteSourceOffset(renderedRange && renderedRange.startUTF16Offset);
    var renderedLength = finiteSourceOffset(renderedRange && renderedRange.utf16Length);
    if (!source || !rendered || renderedStart === null || renderedLength === null || renderedLength <= 0) {
      return null;
    }

    var candidates = sourceMappingSearchCandidates(renderedRange && renderedRange.selectedText);
    for (var candidateIndex = 0; candidateIndex < candidates.length; candidateIndex += 1) {
      var candidate = candidates[candidateIndex];
      var directEnd = renderedStart + candidate.length;
      if (directEnd <= source.length && source.slice(renderedStart, directEnd) === candidate) {
        return { start: renderedStart, end: directEnd };
      }

      var sourceRanges = textRangesOf(source, candidate);
      if (sourceRanges.length === 1) {
        return sourceRanges[0];
      }

      var renderedRanges = textRangesOf(rendered, candidate);
      var renderedOccurrenceIndex = renderedRanges.findIndex(function(range) {
        return renderedRangeContainsCandidate(renderedRange, range);
      });
      if (
        renderedOccurrenceIndex >= 0
        && sourceRanges.length === renderedRanges.length
        && sourceRanges[renderedOccurrenceIndex]
      ) {
        return sourceRanges[renderedOccurrenceIndex];
      }
    }

    return null;
  }

  function mainTextBlockElementForKey(article, blockKey) {
    if (!article || !blockKey) {
      return null;
    }
    return Array.from(article.querySelectorAll('[data-block-type="main_text"]')).find(function(blockElement) {
      return trimmed(blockElement && blockElement.dataset && blockElement.dataset.blockKey) === blockKey;
    }) || null;
  }

  function finiteSourceOffset(value) {
    var number = Number(value);
    return Number.isFinite(number) && number >= 0 ? Math.trunc(number) : null;
  }

  function intersectsRange(range, node) {
    try {
      return range && node && range.intersectsNode(node);
    } catch (error) {
      return false;
    }
  }

  function closestElement(node) {
    if (!node) {
      return null;
    }
    return node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
  }

  function closestMessageElement(node) {
    var element = closestElement(node);
    return element && element.closest ? element.closest('article.message[data-message-id]') : null;
  }

  function eventMessageElement(event) {
    return event && event.target ? closestMessageElement(event.target) : null;
  }

  function eventTargetsMainText(event) {
    return Boolean(event && event.target && closestMainTextBlock(event.target));
  }

  function closestMainTextBlock(node) {
    var element = closestElement(node);
    return element && element.closest
      ? element.closest('[data-block-type="main_text"]')
      : null;
  }

  function closestSourceElement(node) {
    var element = closestElement(node);
    return element && element.closest
      ? element.closest('[data-chat-transcript-source-start][data-chat-transcript-source-end]')
      : null;
  }

  function sourceRangeForElement(element, maximumLength) {
    if (!element || !element.dataset) {
      return null;
    }

    var start = finiteSourceOffset(element.dataset.exampleChatSourceStart);
    var end = finiteSourceOffset(element.dataset.exampleChatSourceEnd);
    if (start === null || end === null || end <= start || end > maximumLength) {
      return null;
    }

    return {
      element: element,
      start: start,
      end: end,
      length: end - start,
      kind: trimmed(element.dataset.exampleChatSourceKind) || 'block'
    };
  }

  function sourceRangePriority(item) {
    return item && (item.kind === 'math-inline' || item.kind === 'math-display') ? 0 : 1;
  }

  function compareSourceRangeCandidates(lhs, rhs) {
    var priorityDiff = sourceRangePriority(lhs) - sourceRangePriority(rhs);
    if (priorityDiff !== 0) {
      return priorityDiff;
    }
    if (lhs.length !== rhs.length) {
      return lhs.length - rhs.length;
    }
    if (lhs.start !== rhs.start) {
      return lhs.start - rhs.start;
    }
    return lhs.end - rhs.end;
  }

  function collectPreferredSourceRanges(range, sourceElements, maximumLength) {
    if (!range) {
      return [];
    }

    var candidatesByKey = new Map();

    function addCandidate(element) {
      var candidate = sourceRangeForElement(element, maximumLength);
      if (!candidate) {
        return;
      }
      var key = String(candidate.start) + ':' + String(candidate.end) + ':' + candidate.kind;
      if (!candidatesByKey.has(key)) {
        candidatesByKey.set(key, candidate);
      }
    }

    addCandidate(closestSourceElement(range.startContainer));
    addCandidate(closestSourceElement(range.endContainer));

    var ancestor = range.commonAncestorContainer;
    var ancestorElement = ancestor && ancestor.nodeType === Node.ELEMENT_NODE ? ancestor : ancestor && ancestor.parentElement;
    if (ancestorElement) {
      addCandidate(
        ancestorElement.matches && ancestorElement.matches('[data-chat-transcript-source-start][data-chat-transcript-source-end]')
          ? ancestorElement
          : null
      );

      sourceElements.forEach(function(sourceElement) {
        if (intersectsRange(range, sourceElement)) {
          addCandidate(sourceElement);
        }
      });
    }

    var candidates = Array.from(candidatesByKey.values());
    if (!candidates.length) {
      return [];
    }

    var containingCandidates = candidates.filter(function(candidate) {
      return candidate.element.contains(range.startContainer) && candidate.element.contains(range.endContainer);
    });
    if (!containingCandidates.length) {
      return candidates;
    }

    containingCandidates.sort(compareSourceRangeCandidates);
    return [containingCandidates[0]];
  }

  function messageByID(messageID) {
    var payloadModel = window.__chatTranscriptPayloadModel;
    if (payloadModel && typeof payloadModel.messageByID === 'function') {
      return payloadModel.messageByID(messageID);
    }
    var payloadStore = window.__chatTranscriptPayloadStore;
    return payloadStore && typeof payloadStore.messageByID === 'function'
      ? payloadStore.messageByID(messageID)
      : null;
  }

  function renderableMessageBlocks(message) {
    var runtimeModel = window.__chatTranscriptMessageRuntimeModel;
    return runtimeModel && typeof runtimeModel.renderableMessageBlocks === 'function'
      ? runtimeModel.renderableMessageBlocks(message)
      : [];
  }

  function blockKeyFor(block, index) {
    var renderer = window.__chatTranscriptMessageBlockRenderer;
    if (renderer && typeof renderer.messageBlockKey === 'function') {
      return renderer.messageBlockKey(block, index);
    }
    return trimmed(block && block.id) || ('__message_block_' + String(index));
  }

  function blockText(block) {
    if (block && typeof block.text === 'string') {
      return block.text;
    }
    if (block && typeof block.content === 'string') {
      return block.content;
    }
    return '';
  }

  function messageMainTextMetadata(message) {
    var blocks = [];
    var parts = [];
    var cursor = 0;

    renderableMessageBlocks(message).forEach(function(block, index) {
      if (!block || block.type !== 'main_text') {
        return;
      }

      var text = blockText(block);
      if (!trimmed(text)) {
        return;
      }

      if (blocks.length > 0) {
        cursor += 2;
      }

      var item = {
        key: blockKeyFor(block, index),
        text: text,
        start: cursor,
        end: cursor + text.length
      };
      blocks.push(item);
      parts.push(text);
      cursor = item.end;
    });

    var blocksByKey = new Map();
    blocks.forEach(function(block) {
      blocksByKey.set(block.key, block);
    });

    return {
      fullMarkdown: parts.join('\n\n'),
      blocks: blocks,
      blocksByKey: blocksByKey
    };
  }

  function selectionArticle(selection) {
    if (!selection || selection.rangeCount <= 0 || selection.isCollapsed) {
      return null;
    }

    var article = null;
    for (var index = 0; index < selection.rangeCount; index += 1) {
      var range = selection.getRangeAt(index);
      var startArticle = closestMessageElement(range.startContainer);
      var endArticle = closestMessageElement(range.endContainer);
      if (!startArticle || startArticle !== endArticle) {
        return null;
      }
      if (!article) {
        article = startArticle;
        continue;
      }
      if (article !== startArticle) {
        return null;
      }
    }
    return article;
  }

  function selectionIntersectsArticle(selection, article) {
    if (!selection || !article || selection.rangeCount <= 0 || selection.isCollapsed) {
      return false;
    }
    for (var index = 0; index < selection.rangeCount; index += 1) {
      if (intersectsRange(selection.getRangeAt(index), article)) {
        return true;
      }
    }
    return false;
  }

  function rangeTouchesMainTextBlock(range, blockElement) {
    if (!range || !blockElement) {
      return false;
    }

    return intersectsRange(range, blockElement)
      || closestMainTextBlock(range.startContainer) === blockElement
      || closestMainTextBlock(range.endContainer) === blockElement;
  }

  function selectedMainTextBlockElements(article, selection) {
    return Array.from(article.querySelectorAll('[data-block-type="main_text"]')).filter(function(blockElement) {
      for (var index = 0; index < selection.rangeCount; index += 1) {
        if (rangeTouchesMainTextBlock(selection.getRangeAt(index), blockElement)) {
          return true;
        }
      }
      return false;
    });
  }

  function selectedBlockLocalSourceRanges(blockElement, selection, blockTextLength) {
    if (!blockElement || !selection || selection.rangeCount <= 0) {
      return [];
    }

    var rangesByKey = new Map();
    var sourceElements = [];
    if (blockElement.matches && blockElement.matches('[data-chat-transcript-source-start][data-chat-transcript-source-end]')) {
      sourceElements.push(blockElement);
    }
    sourceElements = sourceElements.concat(
      Array.from(blockElement.querySelectorAll('[data-chat-transcript-source-start][data-chat-transcript-source-end]'))
    );

    for (var index = 0; index < selection.rangeCount; index += 1) {
      var range = selection.getRangeAt(index);
      if (!rangeTouchesMainTextBlock(range, blockElement)) {
        continue;
      }

      collectPreferredSourceRanges(range, sourceElements, blockTextLength).forEach(function(candidate) {
        if (!candidate || !blockElement.contains(candidate.element)) {
          return;
        }
        var key = String(candidate.start) + ':' + String(candidate.end);
        if (!rangesByKey.has(key)) {
          rangesByKey.set(key, { start: candidate.start, end: candidate.end });
        }
      });
    }

    return Array.from(rangesByKey.values()).sort(function(lhs, rhs) {
      if (lhs.start === rhs.start) {
        return lhs.end - rhs.end;
      }
      return lhs.start - rhs.start;
    });
  }

  function selectedLocalSourceRanges(blockElement, selection, blockText) {
    var source = String(blockText || '');
    if (!blockElement || !selection || selection.rangeCount <= 0 || !source) {
      return [];
    }

    var renderedBlockText = renderedBlockTextIndex(blockElement).text;
    var renderedRanges = selectedRenderedTextRangesForBlock(blockElement, selection);
    if (renderedRanges.length && renderedBlockText) {
      var mappedRanges = [];
      var mappedAllRanges = true;
      renderedRanges.forEach(function(renderedRange) {
        var mappedRange = localPromptSourceRangeForRenderedRange(source, renderedBlockText, renderedRange);
        if (!mappedRange) {
          mappedAllRanges = false;
          return;
        }
        mappedRanges.push(mappedRange);
      });
      if (mappedAllRanges && mappedRanges.length === renderedRanges.length) {
        return mergeSourceRanges(mappedRanges);
      }
    }

    return selectedBlockLocalSourceRanges(blockElement, selection, source.length);
  }

  function mergeSourceRanges(ranges) {
    var sorted = (ranges || [])
      .map(function(range) {
        var start = finiteSourceOffset(range && range.start);
        var end = finiteSourceOffset(range && range.end);
        return start !== null && end !== null && end > start ? { start: start, end: end } : null;
      })
      .filter(Boolean)
      .sort(function(lhs, rhs) {
        if (lhs.start === rhs.start) {
          return lhs.end - rhs.end;
        }
        return lhs.start - rhs.start;
      });

    var merged = [];
    sorted.forEach(function(range) {
      var previous = merged.length ? merged[merged.length - 1] : null;
      if (previous && range.start <= previous.end) {
        previous.end = Math.max(previous.end, range.end);
        return;
      }
      merged.push(range);
    });
    return merged;
  }

  function occurrenceIndexBeforeSelection(article, selection, selectedText) {
    var needle = trimmed(selectedText);
    if (!article || !selection || selection.rangeCount <= 0 || !needle) {
      return null;
    }

    try {
      var range = selection.getRangeAt(0);
      var prefixRange = document.createRange();
      prefixRange.selectNodeContents(article);
      prefixRange.setEnd(range.startContainer, range.startOffset);
      var prefixText = String(prefixRange.toString() || '').toLocaleLowerCase();
      var loweredNeedle = needle.toLocaleLowerCase();
      var count = 0;
      var nextIndex = prefixText.indexOf(loweredNeedle);
      while (nextIndex !== -1) {
        count += 1;
        nextIndex = prefixText.indexOf(loweredNeedle, nextIndex + loweredNeedle.length);
      }
      return count;
    } catch (_) {
      return null;
    }
  }

  function ensureNativeSelectionClearStyle() {
    var style = document.getElementById(nativeSelectionClearStyleID);
    if (!style) {
      style = document.createElement('style');
      style.id = nativeSelectionClearStyleID;
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = [
      'html[data-chat-transcript-suppress-native-selection="true"],',
      'html[data-chat-transcript-suppress-native-selection="true"] * {',
      '  -webkit-user-select: none !important;',
      '  user-select: none !important;',
      '}',
      'html[data-chat-transcript-suppress-native-selection="true"] ::selection {',
      '  background: transparent !important;',
      '  color: inherit !important;',
      '}'
    ].join('\n');
  }

  function suppressNativeSelectionForRepaint() {
    var root = document.documentElement;
    if (!root) {
      return;
    }
    ensureNativeSelectionClearStyle();
    root.setAttribute('data-chat-transcript-suppress-native-selection', 'true');
    try {
      void root.offsetHeight;
    } catch (_) {}
    var restore = function() {
      root.removeAttribute('data-chat-transcript-suppress-native-selection');
    };
    try {
      if (window.requestAnimationFrame) {
        window.requestAnimationFrame(function() {
          window.requestAnimationFrame(restore);
        });
        return;
      }
    } catch (_) {}
    window.setTimeout(restore, 32);
  }

  function clearNativeSelection(forceRepaint) {
    try {
      var selection = window.getSelection ? window.getSelection() : null;
      if (selection) {
        if (typeof selection.removeAllRanges === 'function') {
          selection.removeAllRanges();
        }
        if (typeof selection.empty === 'function') {
          selection.empty();
        }
        if (forceRepaint && typeof selection.addRange === 'function') {
          var root = document.body || document.documentElement;
          if (root) {
            var range = document.createRange();
            range.selectNodeContents(root);
            range.collapse(true);
            selection.removeAllRanges();
            selection.addRange(range);
            selection.removeAllRanges();
          }
        }
      }
    } catch (_) {}
    if (forceRepaint) {
      suppressNativeSelectionForRepaint();
    }
  }

  function setNativeSelectionRange(range) {
    if (!range || !trimmed(range.toString())) {
      return false;
    }
    try {
      var selection = window.getSelection ? window.getSelection() : null;
      if (!selection || typeof selection.removeAllRanges !== 'function' || typeof selection.addRange !== 'function') {
        return false;
      }
      selection.removeAllRanges();
      selection.addRange(range);
      return true;
    } catch (_) {
      return false;
    }
  }

  function caretBoundaryFromPoint(clientX, clientY) {
    try {
      if (document.caretPositionFromPoint) {
        var position = document.caretPositionFromPoint(clientX, clientY);
        if (position && position.offsetNode) {
          return { node: position.offsetNode, offset: position.offset };
        }
      }
      if (document.caretRangeFromPoint) {
        var range = document.caretRangeFromPoint(clientX, clientY);
        if (range) {
          return { node: range.startContainer, offset: range.startOffset };
        }
      }
    } catch (_) {}
    return null;
  }

  function boundaryMessageElement(boundary) {
    return boundary && boundary.node ? closestMessageElement(boundary.node) : null;
  }

  function compareCaretBoundaries(lhs, rhs) {
    try {
      var lhsRange = document.createRange();
      lhsRange.setStart(lhs.node, lhs.offset);
      lhsRange.collapse(true);
      var rhsRange = document.createRange();
      rhsRange.setStart(rhs.node, rhs.offset);
      rhsRange.collapse(true);
      return lhsRange.compareBoundaryPoints(Range.START_TO_START, rhsRange);
    } catch (_) {
      return 0;
    }
  }

  function domRangeFromCaretBoundaries(startBoundary, endBoundary) {
    if (!startBoundary || !endBoundary) {
      return null;
    }
    var startArticle = boundaryMessageElement(startBoundary);
    var endArticle = boundaryMessageElement(endBoundary);
    if (!startArticle || startArticle !== endArticle) {
      return null;
    }

    var start = startBoundary;
    var end = endBoundary;
    if (compareCaretBoundaries(startBoundary, endBoundary) > 0) {
      start = endBoundary;
      end = startBoundary;
    }

    try {
      var range = document.createRange();
      range.setStart(start.node, start.offset);
      range.setEnd(end.node, end.offset);
      return trimmed(range.toString()) ? range : null;
    } catch (_) {
      return null;
    }
  }

  function selectionLikeForRange(range) {
    return {
      rangeCount: range ? 1 : 0,
      isCollapsed: !range || range.collapsed,
      getRangeAt: function(index) {
        if (index !== 0 || !range) {
          throw new Error('Selection range index out of bounds');
        }
        return range;
      },
      toString: function() {
        return range ? range.toString() : '';
      }
    };
  }

  function clearMultiSelectionVisuals() {
    try {
      if (window.CSS && CSS.highlights && typeof CSS.highlights.delete === 'function') {
        CSS.highlights.delete(multiSelectionHighlightName);
      }
    } catch (_) {}

    var selector = '[' + multiSelectionMarkAttribute + '], mark.chat-transcript-multi-selection-mark';
    for (var pass = 0; pass < 8; pass += 1) {
      var marks = Array.from(document.querySelectorAll(selector));
      if (!marks.length) {
        break;
      }
      marks.forEach(function(element) {
        var parent = element.parentNode;
        if (!parent) {
          return;
        }
        if ((element.tagName || '').toUpperCase() === 'MARK') {
          while (element.firstChild) {
            parent.insertBefore(element.firstChild, element);
          }
          parent.removeChild(element);
          parent.normalize();
          return;
        }
        parent.removeChild(element);
      });
    }
  }

  function scheduleMultiSelectionVisualCleanup() {
    function cleanupIfEmpty() {
      if (!multiSelectionState) {
        clearNativeSelection(true);
        clearMultiSelectionVisuals();
      }
    }

    try {
      if (window.requestAnimationFrame) {
        window.requestAnimationFrame(cleanupIfEmpty);
        window.requestAnimationFrame(function() {
          window.requestAnimationFrame(cleanupIfEmpty);
        });
      }
      window.setTimeout(cleanupIfEmpty, 0);
      window.setTimeout(cleanupIfEmpty, 80);
    } catch (_) {
      cleanupIfEmpty();
    }
  }

  function clampedUnit(value, fallback) {
    var number = Number(value);
    if (!Number.isFinite(number)) {
      return fallback;
    }
    return Math.max(0, Math.min(1, number));
  }

  function normalizedMultiSelectionHighlightColor(color) {
    color = color || {};
    return {
      red: clampedUnit(color.red, defaultMultiSelectionHighlightColor.red),
      green: clampedUnit(color.green, defaultMultiSelectionHighlightColor.green),
      blue: clampedUnit(color.blue, defaultMultiSelectionHighlightColor.blue),
      alpha: clampedUnit(color.alpha, defaultMultiSelectionHighlightColor.alpha)
    };
  }

  function rgbaString(color, alphaMultiplier) {
    var resolvedColor = normalizedMultiSelectionHighlightColor(color);
    var alpha = clampedUnit(resolvedColor.alpha * (alphaMultiplier == null ? 1 : alphaMultiplier), resolvedColor.alpha);
    return 'rgba('
      + String(Math.round(resolvedColor.red * 255)) + ', '
      + String(Math.round(resolvedColor.green * 255)) + ', '
      + String(Math.round(resolvedColor.blue * 255)) + ', '
      + String(alpha) + ')';
  }

  function ensureMultiSelectionHighlightStyle() {
    var style = document.getElementById(multiSelectionHighlightStyleID);
    if (!style) {
      style = document.createElement('style');
      style.id = multiSelectionHighlightStyleID;
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = [
      '::highlight(' + multiSelectionHighlightName + ') {',
      '  background-color: ' + rgbaString(multiSelectionHighlightColor, 1) + ';',
      '  color: inherit;',
      '}',
      'mark[' + multiSelectionMarkAttribute + '] {',
      '  background-color: ' + rgbaString(multiSelectionHighlightColor, 1) + ';',
      '  color: inherit;',
      '  border-radius: 0.18em;',
      '  padding: 0;',
      '}'
    ].join('\n');
  }

  window.__chatTranscriptSetMultiSelectionHighlightColor = function(color) {
    multiSelectionHighlightColor = normalizedMultiSelectionHighlightColor(color);
    ensureMultiSelectionHighlightStyle();
    applyMultiSelectionMarks();
    return true;
  };

  window.__chatTranscriptMultiSelectionHighlightColor = multiSelectionHighlightColor;

  function localRenderedCaretLocation(boundary) {
    if (!boundary || !boundary.node) {
      return null;
    }
    var blockElement = closestMainTextBlock(boundary.node);
    var blockKey = trimmed(blockElement && blockElement.dataset && blockElement.dataset.blockKey);
    if (!blockElement || !blockKey) {
      return null;
    }
    var textIndex = renderedBlockTextIndex(blockElement);
    for (var index = 0; index < textIndex.entries.length; index += 1) {
      var entry = textIndex.entries[index];
      if (entry.node !== boundary.node) {
        continue;
      }
      var nodeLength = (entry.node.nodeValue || '').length;
      var offset = Math.max(0, Math.min(boundary.offset, nodeLength));
      return {
        blockKey: blockKey,
        offset: entry.start + offset
      };
    }
    return null;
  }

  function eventHitsMultiSelection(event) {
    if (!multiSelectionState || !event) {
      return false;
    }
    if (eventTargetsMultiSelectionMessage(event)) {
      return true;
    }
    if (eventPointHitsMultiSelectionRects(event)) {
      return true;
    }
    var targetArticle = eventMessageElement(event);
    if (!targetArticle || trimmed(targetArticle.dataset.messageId) !== multiSelectionState.messageID) {
      return false;
    }
    var location = localRenderedCaretLocation(
      caretBoundaryFromPoint(Number(event.clientX) || 0, Number(event.clientY) || 0)
    );
    if (!location) {
      return false;
    }
    return intervalsForBlock(multiSelectionState.renderedTextRanges, location.blockKey).some(function(interval) {
      return location.offset >= interval.start && location.offset <= interval.end;
    });
  }

  function eventTargetsMultiSelectionMessage(event) {
    if (!multiSelectionState || !event) {
      return false;
    }
    var targetArticle = eventMessageElement(event);
    return Boolean(targetArticle && trimmed(targetArticle.dataset.messageId) === multiSelectionState.messageID);
  }

  function eventPointHitsMultiSelectionRects(event) {
    if (!multiSelectionState || !event) {
      return false;
    }
    var article = articleForMessageID(multiSelectionState.messageID);
    if (!article) {
      return false;
    }
    var x = Number(event.clientX);
    var y = Number(event.clientY);
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      return false;
    }
    var hitSlop = 3;
    return (multiSelectionState.renderedTextRanges || []).some(function(renderedRange) {
      var domRange = domRangeForRenderedTextRange(
        mainTextBlockElementForKey(article, renderedRange.blockKey),
        renderedRange
      );
      if (!domRange) {
        return false;
      }
      return Array.from(domRange.getClientRects()).some(function(rect) {
        return x >= rect.left - hitSlop
          && x <= rect.right + hitSlop
          && y >= rect.top - hitSlop
          && y <= rect.bottom + hitSlop;
      });
    });
  }

  function textIndexEntryAtOffset(textIndex, offset, usePrevious) {
    if (!textIndex || !textIndex.entries.length) {
      return null;
    }
    var targetOffset = Math.trunc(Number(offset));
    if (!Number.isFinite(targetOffset)) {
      return null;
    }
    for (var index = 0; index < textIndex.entries.length; index += 1) {
      var entry = textIndex.entries[index];
      if (targetOffset >= entry.start && targetOffset < entry.end) {
        return { node: entry.node, offset: targetOffset - entry.start };
      }
      if (!usePrevious && targetOffset === entry.end) {
        return { node: entry.node, offset: entry.end - entry.start };
      }
    }
    if (usePrevious && targetOffset === textIndex.text.length) {
      var last = textIndex.entries[textIndex.entries.length - 1];
      return { node: last.node, offset: last.end - last.start };
    }
    return null;
  }

  function domRangeForRenderedTextRange(blockElement, renderedRange) {
    if (!blockElement || !renderedRange) {
      return null;
    }
    var start = finiteSourceOffset(renderedRange.startUTF16Offset);
    var length = finiteSourceOffset(renderedRange.utf16Length);
    if (start === null || length === null || length <= 0) {
      return null;
    }

    var textIndex = renderedBlockTextIndex(blockElement);
    var end = start + length;
    if (!textIndex.text || end > textIndex.text.length) {
      return null;
    }

    var startEntry = textIndexEntryAtOffset(textIndex, start, false);
    var endEntry = textIndexEntryAtOffset(textIndex, end, true);
    if (!startEntry || !endEntry) {
      return null;
    }

    try {
      var range = document.createRange();
      range.setStart(startEntry.node, startEntry.offset);
      range.setEnd(endEntry.node, endEntry.offset);
      if (!trimmed(range.toString())) {
        return null;
      }
      return range;
    } catch (_) {
      return null;
    }
  }

  function markMultiSelectionTextNodesForRange(range) {
    if (!range) {
      return false;
    }

    var root = range.commonAncestorContainer;
    var walkerRoot = root && root.nodeType === Node.TEXT_NODE ? root.parentNode : root;
    if (!walkerRoot) {
      return false;
    }

    var slices = [];
    var walker = document.createTreeWalker(walkerRoot, NodeFilter.SHOW_TEXT, {
      acceptNode: function(node) {
        if (!node || !node.nodeValue || !intersectsRange(range, node)) {
          return NodeFilter.FILTER_REJECT;
        }
        if (!textNodeCanContributeToRenderedRange(node)) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    var current = walker.nextNode();
    while (current) {
      var value = current.nodeValue || '';
      var startOffset = range.startContainer === current ? range.startOffset : 0;
      var endOffset = range.endContainer === current ? range.endOffset : value.length;
      startOffset = Math.max(0, Math.min(startOffset, value.length));
      endOffset = Math.max(0, Math.min(endOffset, value.length));
      if (endOffset > startOffset && trimmed(value.slice(startOffset, endOffset))) {
        slices.push({
          node: current,
          startOffset: startOffset,
          endOffset: endOffset
        });
      }
      current = walker.nextNode();
    }

    var didMark = false;
    slices.forEach(function(slice) {
      var node = slice.node;
      if (!node || !node.parentNode) {
        return;
      }

      var target = node;
      var startOffset = slice.startOffset;
      var endOffset = slice.endOffset;
      if (endOffset < (target.nodeValue || '').length) {
        target.splitText(endOffset);
      }
      if (startOffset > 0) {
        target = target.splitText(startOffset);
      }

      if (!trimmed(target.nodeValue || '') || !target.parentNode) {
        return;
      }

      var mark = document.createElement('mark');
      mark.setAttribute(multiSelectionMarkAttribute, 'true');
      mark.className = 'chat-transcript-multi-selection-mark';
      target.parentNode.insertBefore(mark, target);
      mark.appendChild(target);
      didMark = true;
    });
    return didMark;
  }

  function applyMultiSelectionMarks() {
    clearMultiSelectionVisuals();
    var visualState = multiSelectionState;
    if (!visualState || !visualState.renderedTextRanges.length) {
      return;
    }

    var article = document.querySelector('article.message[data-message-id="' + cssEscape(visualState.messageID) + '"]');
    if (!article) {
      return;
    }
    var ranges = [];
    visualState.renderedTextRanges.forEach(function(range) {
      var domRange = domRangeForRenderedTextRange(mainTextBlockElementForKey(article, range.blockKey), range);
      if (domRange) {
        ranges.push(domRange);
      }
    });
    if (!ranges.length) {
      return;
    }
    ensureMultiSelectionHighlightStyle();
    ranges.forEach(markMultiSelectionTextNodesForRange);
  }

  function clearMultiSelectionState() {
    multiSelectionState = null;
    clearMultiSelectionVisuals();
  }

  function clearMultiSelectionForUser() {
    var hadVisuals = Boolean(document.querySelector('[' + multiSelectionMarkAttribute + '], mark.chat-transcript-multi-selection-mark'));
    var hadSelection = Boolean(multiSelectionState || hadVisuals);
    clearNativeSelection(true);
    multiSelectionDragState = null;
    var cleared = setMultiSelectionState(null, true);
    clearMultiSelectionVisuals();
    scheduleMultiSelectionVisualCleanup();
    postMultiSelectionStateChange();
    return cleared || hadSelection;
  }

  function eventTargetsEditableElement(event) {
    var element = closestElement(event && event.target);
    if (!element) {
      element = document.activeElement;
    }
    if (!element) {
      return false;
    }
    return Boolean(element.closest && element.closest('input, textarea, select, [contenteditable=""], [contenteditable="true"], [role="textbox"]'));
  }

  function canHandleMultiSelectionHistoryShortcut(event, wantsRedo) {
    if (!event || !event.metaKey || event.altKey || event.ctrlKey || eventTargetsEditableElement(event)) {
      return false;
    }
    if (trimmed(event.key).toLowerCase() !== 'z') {
      return false;
    }
    if (wantsRedo) {
      return event.shiftKey && (multiSelectionRedoStack.length > 0 || multiSelectionState);
    }
    return !event.shiftKey && (multiSelectionUndoStack.length > 0 || multiSelectionState);
  }

  function handleMultiSelectionHistoryShortcut(event) {
    var wantsRedo = Boolean(event && event.shiftKey);
    if (!canHandleMultiSelectionHistoryShortcut(event, wantsRedo)) {
      return false;
    }
    if (wantsRedo) {
      redoMultiSelectionChange();
    } else {
      undoMultiSelectionChange();
    }
    if (event) {
      event.preventDefault();
      event.stopPropagation();
      if (typeof event.stopImmediatePropagation === 'function') {
        event.stopImmediatePropagation();
      }
    }
    return true;
  }

  window.__chatTranscriptApplyMultiSelectionHistoryShortcut = function(wantsRedo) {
    if (!multiSelectionState) {
      return false;
    }
    if (wantsRedo) {
      redoMultiSelectionChange();
    } else {
      undoMultiSelectionChange();
    }
    return true;
  };
  window.__chatTranscriptHandleMultiSelectionHistoryShortcut = handleMultiSelectionHistoryShortcut;
  window.__chatTranscriptClearMultiSelection = clearMultiSelectionForUser;

  function selectedTextFromRenderedRanges(ranges) {
    return (ranges || []).map(function(range) {
      return String(range && range.selectedText || '').trim();
    }).filter(function(text) {
      return text.length > 0;
    }).join('\n');
  }

  function cloneRenderedTextRanges(ranges) {
    return (ranges || []).map(function(range) {
      return {
        blockKey: trimmed(range && range.blockKey),
        startUTF16Offset: finiteSourceOffset(range && range.startUTF16Offset) || 0,
        utf16Length: finiteSourceOffset(range && range.utf16Length) || 0,
        selectedText: String(range && range.selectedText || '')
      };
    }).filter(function(range) {
      return range.blockKey && range.utf16Length > 0;
    });
  }

  function cloneSourceRanges(ranges) {
    return (ranges || []).map(function(range) {
      var start = finiteSourceOffset(range && range.start);
      var end = finiteSourceOffset(range && range.end);
      return start !== null && end !== null && end > start ? { start: start, end: end } : null;
    }).filter(Boolean);
  }

  function cloneMultiSelectionState(state) {
    if (!state || !state.messageID || !state.renderedTextRanges || !state.renderedTextRanges.length) {
      return null;
    }
    return {
      messageID: state.messageID,
      messageRole: state.messageRole,
      renderedTextRanges: cloneRenderedTextRanges(state.renderedTextRanges),
      sourceRanges: cloneSourceRanges(state.sourceRanges),
      sourceBaseMarkdown: String(state.sourceBaseMarkdown || ''),
      selectedText: String(state.selectedText || ''),
      renderedTextSegments: (state.renderedTextSegments || []).map(String),
      type: state.type || 'selection'
    };
  }

  function multiSelectionStateSignature(state) {
    var snapshot = cloneMultiSelectionState(state);
    return snapshot ? JSON.stringify(snapshot) : '';
  }

  function articleForMessageID(messageID) {
    return messageID
      ? document.querySelector('article.message[data-message-id="' + cssEscape(messageID) + '"]')
      : null;
  }

  function textForRenderedInterval(article, blockKey, start, end) {
    var blockElement = mainTextBlockElementForKey(article, blockKey);
    var blockText = blockElement ? renderedBlockTextIndex(blockElement).text : '';
    return blockText && end <= blockText.length ? blockText.slice(start, end) : '';
  }

  function renderedIntervalPayload(article, blockKey, start, end) {
    return {
      blockKey: blockKey,
      startUTF16Offset: start,
      utf16Length: end - start,
      selectedText: textForRenderedInterval(article, blockKey, start, end)
    };
  }

  function subtractIntervalSegments(segments, start, end) {
    var next = [];
    segments.forEach(function(segment) {
      if (segment.end <= start || segment.start >= end) {
        next.push(segment);
        return;
      }
      if (segment.start < start) {
        next.push({ start: segment.start, end: start });
      }
      if (end < segment.end) {
        next.push({ start: end, end: segment.end });
      }
    });
    return next;
  }

  function intervalsForBlock(ranges, blockKey) {
    return mergeRenderedTextRanges((ranges || []).map(function(range) {
      if (trimmed(range && range.blockKey) !== blockKey) {
        return null;
      }
      var start = finiteSourceOffset(range && range.startUTF16Offset);
      var length = finiteSourceOffset(range && range.utf16Length);
      return start !== null && length !== null && length > 0
        ? { start: start, end: start + length }
        : null;
    }).filter(Boolean));
  }

  function toggleRenderedRangePayloads(article, existingRanges, incomingRanges) {
    var blockKeys = new Set();
    (existingRanges || []).forEach(function(range) {
      var blockKey = trimmed(range && range.blockKey);
      if (blockKey) {
        blockKeys.add(blockKey);
      }
    });
    (incomingRanges || []).forEach(function(range) {
      var blockKey = trimmed(range && range.blockKey);
      if (blockKey) {
        blockKeys.add(blockKey);
      }
    });

    var toggled = [];
    Array.from(blockKeys).sort().forEach(function(blockKey) {
      var resultIntervals = intervalsForBlock(existingRanges, blockKey);
      intervalsForBlock(incomingRanges, blockKey).forEach(function(incoming) {
        var additions = [{ start: incoming.start, end: incoming.end }];
        var nextResult = [];
        resultIntervals.forEach(function(existing) {
          if (existing.end <= incoming.start || existing.start >= incoming.end) {
            nextResult.push(existing);
            return;
          }
          if (existing.start < incoming.start) {
            nextResult.push({ start: existing.start, end: incoming.start });
          }
          if (incoming.end < existing.end) {
            nextResult.push({ start: incoming.end, end: existing.end });
          }
          additions = subtractIntervalSegments(additions, existing.start, existing.end);
        });
        resultIntervals = nextResult.concat(additions);
      });

      mergeRenderedTextRanges(resultIntervals).forEach(function(interval) {
        toggled.push(renderedIntervalPayload(article, blockKey, interval.start, interval.end));
      });
    });

    return mergeRenderedTextRangePayloads(article, toggled);
  }

  function sourceRangesFromRenderedRanges(messageID, renderedRanges) {
    var message = messageByID(messageID);
    var metadata = messageMainTextMetadata(message);
    var article = articleForMessageID(messageID);
    var sourceRanges = [];
    (renderedRanges || []).forEach(function(range) {
      var blockKey = trimmed(range && range.blockKey);
      var blockMetadata = metadata.blocksByKey.get(blockKey);
      var start = finiteSourceOffset(range && range.startUTF16Offset);
      var length = finiteSourceOffset(range && range.utf16Length);
      if (!blockMetadata || start === null || length === null || length <= 0) {
        return;
      }
      var blockElement = article ? mainTextBlockElementForKey(article, blockKey) : null;
      var renderedBlockText = blockElement ? renderedBlockTextIndex(blockElement).text : '';
      var mappedRange = localPromptSourceRangeForRenderedRange(
        blockMetadata.text,
        renderedBlockText,
        range
      );
      if (mappedRange) {
        sourceRanges.push({
          start: blockMetadata.start + mappedRange.start,
          end: blockMetadata.start + mappedRange.end
        });
        return;
      }

      var end = start + length;
      if (
        end > blockMetadata.text.length
        || blockMetadata.text.slice(start, end) !== String(range && range.selectedText || '')
      ) {
        return;
      }
      sourceRanges.push({
        start: blockMetadata.start + start,
        end: blockMetadata.start + end
      });
    });
    return mergeSourceRanges(sourceRanges);
  }

  function normalizedMultiSelectionState(state) {
    var snapshot = cloneMultiSelectionState(state);
    if (!snapshot || !snapshot.messageID) {
      return null;
    }
    var article = articleForMessageID(snapshot.messageID);
    if (!article) {
      return null;
    }
    snapshot.renderedTextRanges = mergeRenderedTextRangePayloads(article, snapshot.renderedTextRanges);
    if (!snapshot.renderedTextRanges.length) {
      return null;
    }
    snapshot.selectedText = selectedTextFromRenderedRanges(snapshot.renderedTextRanges);
    snapshot.renderedTextSegments = snapshot.renderedTextRanges
      .map(function(range) { return normalizedRenderedSegment(range.selectedText); })
      .filter(function(segment, index, array) {
        return segment && array.indexOf(segment) === index;
      });
    snapshot.sourceRanges = sourceRangesFromRenderedRanges(snapshot.messageID, snapshot.renderedTextRanges);
    if (!snapshot.sourceBaseMarkdown) {
      snapshot.sourceBaseMarkdown = messageMainTextMetadata(messageByID(snapshot.messageID)).fullMarkdown || '';
    }
    return snapshot;
  }

  function setMultiSelectionState(nextState, recordsHistory) {
    var before = cloneMultiSelectionState(multiSelectionState);
    var after = normalizedMultiSelectionState(nextState);
    if (multiSelectionStateSignature(before) === multiSelectionStateSignature(after)) {
      return false;
    }
    if (recordsHistory) {
      multiSelectionUndoStack.push(before);
      if (multiSelectionUndoStack.length > multiSelectionHistoryLimit) {
        multiSelectionUndoStack.shift();
      }
      multiSelectionRedoStack = [];
    }
    multiSelectionState = after;
    applyMultiSelectionMarks();
    return true;
  }

  function postMultiSelectionStateChange() {
    postSelectionContextMenuPayload(
      multiSelectionPayload('selection', null, false) || { selectedText: '', type: 'selection' }
    );
  }

  function undoMultiSelectionChange() {
    if (!multiSelectionUndoStack.length) {
      return false;
    }
    multiSelectionRedoStack.push(cloneMultiSelectionState(multiSelectionState));
    multiSelectionState = normalizedMultiSelectionState(multiSelectionUndoStack.pop());
    multiSelectionDragState = null;
    applyMultiSelectionMarks();
    postMultiSelectionStateChange();
    return true;
  }

  function redoMultiSelectionChange() {
    if (!multiSelectionRedoStack.length) {
      return false;
    }
    multiSelectionUndoStack.push(cloneMultiSelectionState(multiSelectionState));
    multiSelectionState = normalizedMultiSelectionState(multiSelectionRedoStack.pop());
    multiSelectionDragState = null;
    applyMultiSelectionMarks();
    postMultiSelectionStateChange();
    return true;
  }

  function nextMultiSelectionStateForPayload(payload) {
    var messageID = trimmed(payload && payload.messageID);
    var messageRole = trimmed(payload && payload.messageRole);
    if (!messageID || (messageRole !== 'assistant' && messageRole !== 'user')) {
      return null;
    }

    var article = document.querySelector('article.message[data-message-id="' + cssEscape(messageID) + '"]');
    var renderedRanges = mergeRenderedTextRangePayloads(article, payload.renderedTextRanges || []);
    if (!renderedRanges.length) {
      return null;
    }

    var nextState;
    if (!multiSelectionState || multiSelectionState.messageID !== messageID) {
      nextState = {
        messageID: messageID,
        messageRole: messageRole,
        renderedTextRanges: [],
        sourceRanges: [],
        sourceBaseMarkdown: '',
        type: 'selection'
      };
    } else {
      nextState = cloneMultiSelectionState(multiSelectionState);
    }

    nextState.messageRole = messageRole;
    nextState.renderedTextRanges = toggleRenderedRangePayloads(
      article,
      nextState.renderedTextRanges,
      renderedRanges
    );
    if (payload.sourceBaseMarkdown) {
      nextState.sourceBaseMarkdown = payload.sourceBaseMarkdown;
    }
    return nextState;
  }

  function appendPayloadToMultiSelection(payload) {
    var nextState = nextMultiSelectionStateForPayload(payload);
    if (!nextState) {
      return false;
    }
    return setMultiSelectionState(nextState, true);
  }

  function currentSelectionPayload(includeSourceBase) {
    return selectionPayload('selection', null, includeSourceBase === true, null);
  }

  function appendCurrentSelectionToMultiSelection(includeSourceBase) {
    var payload = currentSelectionPayload(includeSourceBase);
    if (!trimmed(payload && payload.selectedText)) {
      return false;
    }
    return appendPayloadToMultiSelection(payload);
  }

  function appendDomRangeToMultiSelection(range, includeSourceBase) {
    if (!range || !trimmed(range.toString())) {
      return false;
    }
    var payload = selectionPayload('selection', null, includeSourceBase === true, selectionLikeForRange(range));
    if (!trimmed(payload && payload.selectedText)) {
      return false;
    }
    return appendPayloadToMultiSelection(payload);
  }

  function multiSelectionPayload(type, event, includeSourceBase) {
    if (!multiSelectionState || !multiSelectionState.renderedTextRanges.length) {
      return null;
    }

    var targetArticle = eventMessageElement(event);
    if (
      type !== 'contextmenu'
      && targetArticle
      && trimmed(targetArticle.dataset.messageId) !== multiSelectionState.messageID
    ) {
      return null;
    }

    var message = messageByID(multiSelectionState.messageID);
    var metadata = messageMainTextMetadata(message);
    var fullMarkdown = metadata.fullMarkdown || multiSelectionState.sourceBaseMarkdown || '';
    var sourceRanges = mergeSourceRanges(multiSelectionState.sourceRanges);
    var selectedText = selectedTextFromRenderedRanges(multiSelectionState.renderedTextRanges);
    var payload = {
      selectedText: selectedText,
      type: trimmed(type) || 'selection',
      messageID: multiSelectionState.messageID,
      messageRole: multiSelectionState.messageRole,
      renderedTextSegments: multiSelectionState.renderedTextSegments || [],
      renderedTextRanges: multiSelectionState.renderedTextRanges,
      isMultiSelection: true
    };
    if (event) {
      payload.clientX = Number(event.clientX) || 0;
      payload.clientY = Number(event.clientY) || 0;
    }
    if (includeSourceBase === true && fullMarkdown.length > 0) {
      payload.sourceBaseMarkdown = fullMarkdown;
    }
    if (sourceRanges.length && fullMarkdown.length > 0) {
      var start = Math.min.apply(null, sourceRanges.map(function(item) { return item.start; }));
      var end = Math.max.apply(null, sourceRanges.map(function(item) { return item.end; }));
      if (Number.isFinite(start) && Number.isFinite(end) && end > start && end <= fullMarkdown.length) {
        payload.sourceStartUTF16Offset = start;
        payload.sourceUTF16Length = end - start;
        payload.sourceMarkdown = fullMarkdown.slice(start, end);
        payload.sourceRanges = sourceRanges;
      }
    }
    if (!payload.sourceMarkdown) {
      payload.sourceMarkdown = selectedText;
    }
    return payload;
  }

  function multiSelectionEmptyContextPayload(event) {
    if (!multiSelectionState || !multiSelectionState.renderedTextRanges.length) {
      return null;
    }
    var payload = {
      selectedText: '',
      type: 'multiSelectionEmptyContext',
      messageID: multiSelectionState.messageID,
      messageRole: multiSelectionState.messageRole,
      isMultiSelection: true
    };
    if (event) {
      payload.clientX = Number(event.clientX) || 0;
      payload.clientY = Number(event.clientY) || 0;
    }
    return payload;
  }

  function messageSelectionPayloadForArticle(type, event, includeSourceBase, selection, article, selectedTextValue) {
    var renderedTextRanges = selectedRenderedTextRanges(article, selection);
    var text = selectedTextValue == null
      ? selectedTextFromRenderedRanges(renderedTextRanges)
      : String(selectedTextValue);
    var trimmedText = trimmed(text);
    var payload = {
      selectedText: text,
      type: trimmed(type) || 'selection'
    };
    if (event) {
      payload.clientX = Number(event.clientX) || 0;
      payload.clientY = Number(event.clientY) || 0;
    }
    if (!trimmedText) {
      return payload;
    }

    if (!article) {
      return payload;
    }

    var messageID = trimmed(article.dataset.messageId);
    var messageRole = trimmed(article.dataset.messageRole);
    payload.messageID = messageID;
    payload.messageRole = messageRole;
    payload.renderedTextSegments = selectedRenderedTextSegments(article, selection);
    payload.renderedTextRanges = renderedTextRanges;
    if (!messageID || (messageRole !== 'assistant' && messageRole !== 'user')) {
      return payload;
    }
    var occurrenceIndex = occurrenceIndexBeforeSelection(article, selection, trimmedText);
    if (Number.isFinite(occurrenceIndex) && occurrenceIndex >= 0) {
      payload.selectedTextOccurrenceIndexInMessage = occurrenceIndex;
    }

    var message = messageByID(messageID);
    var metadata = messageMainTextMetadata(message);
    var fullMarkdown = metadata.fullMarkdown;
    if (includeSourceBase === true && fullMarkdown.length > 0) {
      payload.sourceBaseMarkdown = fullMarkdown;
    }

    var selectedBlockElements = selectedMainTextBlockElements(article, selection);
    if (!selectedBlockElements.length) {
      return payload;
    }

    var sourceRanges = [];
    selectedBlockElements.forEach(function(blockElement) {
      var blockKey = trimmed(blockElement && blockElement.dataset && blockElement.dataset.blockKey);
      var blockMetadata = metadata.blocksByKey.get(blockKey);
      if (!blockMetadata) {
        return;
      }

      var localRanges = selectedLocalSourceRanges(
        blockElement,
        selection,
        blockMetadata.text
      );

      localRanges.forEach(function(localRange) {
        sourceRanges.push({
          start: blockMetadata.start + localRange.start,
          end: blockMetadata.start + localRange.end
        });
      });
    });

    if (!sourceRanges.length) {
      return payload;
    }
    payload.sourceRanges = mergeSourceRanges(sourceRanges);

    var start = Math.min.apply(null, sourceRanges.map(function(item) { return item.start; }));
    var end = Math.max.apply(null, sourceRanges.map(function(item) { return item.end; }));
    if (Number.isFinite(start) && Number.isFinite(end) && end > start && end <= fullMarkdown.length) {
      payload.sourceMarkdown = fullMarkdown.slice(start, end);
      payload.sourceStartUTF16Offset = start;
      payload.sourceUTF16Length = end - start;
    } else {
      payload.sourceMarkdown = trimmedText;
    }
    return payload;
  }

  function selectionPayload(type, event, includeSourceBase, selectionOverride) {
    var text = selectionOverride ? String(selectionOverride.toString()) : selectedText();
    var trimmedText = trimmed(text);
    var payload = {
      selectedText: text,
      type: trimmed(type) || 'selection'
    };
    if (event) {
      payload.clientX = Number(event.clientX) || 0;
      payload.clientY = Number(event.clientY) || 0;
    }
    if (!trimmedText) {
      return payload;
    }

    var selection = selectionOverride || (window.getSelection ? window.getSelection() : null);
    if (!selection || selection.rangeCount <= 0 || selection.isCollapsed) {
      return payload;
    }

    var article = selectionArticle(selection);
    if (!article) {
      return payload;
    }

    return messageSelectionPayloadForArticle(type, event, includeSourceBase, selection, article, text);
  }

  function postSelectionPayload(type, event) {
    postSelectionContextMenuPayload(multiSelectionPayload(type, event, false) || selectionPayload(type, event, false, null));
  }

  function copyPayloadToClipboardEvent(event, payload) {
    if (!event || !event.clipboardData || typeof event.clipboardData.setData !== 'function') {
      return false;
    }
    var text = String(payload && payload.selectedText || '');
    if (!trimmed(text)) {
      return false;
    }
    event.clipboardData.setData('text/plain', text);
    event.preventDefault();
    event.stopPropagation();
    if (typeof event.stopImmediatePropagation === 'function') {
      event.stopImmediatePropagation();
    }
    postSelectionContextMenuPayload(payload);
    return true;
  }

  function copyShortcutPayload(type) {
    var payload = multiSelectionPayload(type, null, false) || selectionPayload(type, null, false, null);
    if (!trimmed(payload && payload.selectedText)) {
      return null;
    }
    return payload;
  }

  function payloadHasMessageSelection(payload) {
    return Boolean(
      trimmed(payload && payload.selectedText)
      && (payload.messageRole === 'assistant' || payload.messageRole === 'user')
    );
  }

  window.__chatTranscriptCurrentRepairSelectionPayload = function(includeSourceBase) {
    return multiSelectionPayload('selection', null, includeSourceBase === true)
      || selectionPayload('selection', null, includeSourceBase === true, null);
  };

  var selectionPostTimer = null;
  function scheduleSelectionPost() {
    if (selectionPostTimer) {
      window.clearTimeout(selectionPostTimer);
    }
    selectionPostTimer = window.setTimeout(function() {
      selectionPostTimer = null;
      postSelectionPayload('selection', null);
    }, 0);
  }

  document.addEventListener('selectionchange', function() {
    scheduleSelectionPost();
  }, true);
  document.addEventListener('copy', function(event) {
    if (eventTargetsEditableElement(event)) {
      return;
    }
    var options = window.__chatTranscriptSelectionContextMenuOptions || {};
    var payload = copyShortcutPayload('copy');
    if (options.usesNativeSelectionCopy && !(payload && payload.isMultiSelection)) {
      if (payload) {
        postSelectionContextMenuPayload(payload);
      }
      return;
    }
    copyPayloadToClipboardEvent(event, payload);
  }, true);
  document.addEventListener('mousedown', function(event) {
    if (event && event.metaKey && event.button === 0 && eventMessageElement(event)) {
      appendCurrentSelectionToMultiSelection(true);
      clearNativeSelection();
      multiSelectionDragState = {
        start: caretBoundaryFromPoint(Number(event.clientX) || 0, Number(event.clientY) || 0)
      };
      if (multiSelectionDragState.start) {
        event.preventDefault();
        event.stopPropagation();
      }
    } else if (
      event
      && event.button === 0
      && !event.metaKey
      && !event.shiftKey
      && !event.altKey
      && !event.ctrlKey
      && eventHitsMultiSelection(event)
    ) {
      clearNativeSelection();
      postSelectionContextMenuPayload(multiSelectionPayload('selection', null, false));
      event.preventDefault();
      event.stopPropagation();
    } else if (multiSelectionDragState && event && event.button !== 2 && !event.ctrlKey) {
      multiSelectionDragState = null;
    }
  }, true);
  document.addEventListener('mousemove', function(event) {
    if (!(event && event.metaKey && multiSelectionDragState && multiSelectionDragState.start)) {
      return;
    }
    setNativeSelectionRange(
      domRangeFromCaretBoundaries(
        multiSelectionDragState.start,
        caretBoundaryFromPoint(Number(event.clientX) || 0, Number(event.clientY) || 0)
      )
    );
    event.preventDefault();
    event.stopPropagation();
  }, true);
  document.addEventListener('mouseup', function(event) {
    if (event && event.metaKey) {
      var appended = false;
      if (multiSelectionDragState && multiSelectionDragState.start) {
        appended = appendDomRangeToMultiSelection(
          domRangeFromCaretBoundaries(
            multiSelectionDragState.start,
            caretBoundaryFromPoint(Number(event.clientX) || 0, Number(event.clientY) || 0)
          ),
          true
        );
      }
      multiSelectionDragState = null;
      if (!appended) {
        appended = appendCurrentSelectionToMultiSelection(true);
      }
      if (appended) {
        clearNativeSelection();
        postSelectionContextMenuPayload(multiSelectionPayload('selection', null, false));
        event.preventDefault();
        event.stopPropagation();
        return;
      }
    }
    multiSelectionDragState = null;
    applyMultiSelectionMarks();
    scheduleSelectionPost();
  }, true);
  document.addEventListener('keyup', function() {
    scheduleSelectionPost();
  }, true);
  function handleKeyDown(event) {
    if (handleMultiSelectionHistoryShortcut(event)) {
      return;
    }
    var key = trimmed(event && event.key).toLowerCase();
    var options = window.__chatTranscriptSelectionContextMenuOptions || {};
    var acceptsControlCopy = !options.copyShortcutRequiresMeta;
    var isCopyShortcut = key === 'c'
      && !event.shiftKey
      && !event.altKey
      && (event.metaKey || (acceptsControlCopy && event.ctrlKey));
    if (isCopyShortcut && !event.__chatTranscriptCopyShortcutHandled && !eventTargetsEditableElement(event)) {
      var payload = copyShortcutPayload('copyShortcut');
      if (payload) {
        event.__chatTranscriptCopyShortcutHandled = true;
        postSelectionContextMenuPayload(payload);
        if (event.ctrlKey && !event.metaKey) {
          event.preventDefault();
          event.stopPropagation();
          if (typeof event.stopImmediatePropagation === 'function') {
            event.stopImmediatePropagation();
          }
        }
        return;
      }
    }
    if (event && event.key === 'Escape' && multiSelectionState) {
      clearMultiSelectionForUser();
      event.preventDefault();
      event.stopPropagation();
    }
  }
  window.addEventListener('keydown', handleKeyDown, true);
  document.addEventListener('keydown', handleKeyDown, true);
  document.addEventListener('beforeinput', function(event) {
    if (!event || (event.inputType !== 'historyUndo' && event.inputType !== 'historyRedo')) {
      return;
    }
    if (eventTargetsEditableElement(event)) {
      return;
    }
    if (!multiSelectionState) {
      return;
    }
    if (event.inputType === 'historyRedo') {
      redoMultiSelectionChange();
    } else {
      undoMultiSelectionChange();
    }
    if (multiSelectionState || multiSelectionUndoStack.length || multiSelectionRedoStack.length) {
      event.preventDefault();
      event.stopPropagation();
      if (typeof event.stopImmediatePropagation === 'function') {
        event.stopImmediatePropagation();
      }
    }
  }, true);
  document.addEventListener('contextmenu', function(event) {
    var nativeContextMenuPayload = selectionPayload('contextmenu', event, true, null);
    var shouldPreferNativeContextMenuPayload = payloadHasMessageSelection(nativeContextMenuPayload)
      && (
        !multiSelectionState
        || !eventHitsMultiSelection(event)
        || trimmed(nativeContextMenuPayload.messageID) !== multiSelectionState.messageID
      );

    if (multiSelectionState && !shouldPreferNativeContextMenuPayload) {
      var activeMultiSelectionPayload = multiSelectionPayload('contextmenu', event, true);
      if (activeMultiSelectionPayload && selectionContextMenuHandler()) {
        event.preventDefault();
        event.stopPropagation();
        postSelectionContextMenuPayload(activeMultiSelectionPayload);
        return;
      }
    }

    if (multiSelectionState && !shouldPreferNativeContextMenuPayload && !eventTargetsMainText(event) && !eventHitsMultiSelection(event)) {
      var blankPayload = multiSelectionEmptyContextPayload(event);
      if (blankPayload && selectionContextMenuHandler()) {
        event.preventDefault();
        event.stopPropagation();
        postSelectionContextMenuPayload(blankPayload);
        return;
      }
    }

    var payload = shouldPreferNativeContextMenuPayload
      ? nativeContextMenuPayload
      : (multiSelectionPayload('contextmenu', event, true) || nativeContextMenuPayload);
    if (
      trimmed(payload.selectedText) === ''
      || (payload.messageRole !== 'assistant' && payload.messageRole !== 'user')
    ) {
      var emptyContextPayload = multiSelectionEmptyContextPayload(event);
      if (emptyContextPayload && selectionContextMenuHandler()) {
        event.preventDefault();
        event.stopPropagation();
        postSelectionContextMenuPayload(emptyContextPayload);
        return;
      }
      scheduleSelectionPost();
      return;
    }
    if (!selectionContextMenuHandler()) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    postSelectionContextMenuPayload(payload);
  }, true);
})();
