import Foundation
import ModelShellProxy
import MSPCore

extension PhotoSorterMediaCommand {
    static let rootHelp = """
    media

    Usage:
      media list <scope>
      media show <path>...
      media show --from-file <path-list>
      media show --ocr <path>...
      media show --ocr --from-file <path-list>
      media show --vlm <path>...
      media show --vlm --from-file <path-list>
      media status
      media cache status [ocr|vlm|place]
      media vlm status
      media search --ocr <keyword> <path>...
      media search --ocr <keyword> --from-file <path-list>
      media search --ocr --regex <pattern> <path>...
      media search --ocr --regex <pattern> --from-file <path-list>
      media search --vlm <keyword> <path>...
      media search --vlm <keyword> --from-file <path-list>
      media search --vlm --regex <pattern> <path>...
      media search --vlm --regex <pattern> --from-file <path-list>
      media view <path>...
      media view --from-file <path-list>
      media ask [--message <text>] <path>...
      media ask --from-file <path-list> [--message <text>]
      media ask ... [--write-selected <path>] [--write-excluded <path>] [--write-skipped <path>]
      media stats <scope>
      media trash --from-file <path-list>
      media restore --from-file <path-list>

    Help:
      media help list
      media help show
      media help show --ocr
      media help show --vlm
      media help status
      media help cache status
      media help vlm
      media help search --ocr
      media help search --vlm
      media help view
      media help ask
      media help stats
      media help trash
      media help restore
    """

    static let listHelp = """
    media list

    Usage:
      media list <scope> [--limit N] [--offset N] [--sort created|modified|name] [--order asc|desc] [--type image|video|all] [--format paths|tsv|jsonl]

    Description:
      List one bounded page of media paths from a library or album scope.
      Defaults: --limit 3000 --offset 0 --sort created --order desc --type all --format paths.
      The default stdout is one path per line, so it is safe to redirect into a /tmp path list.
      A zero-exit summary is printed to stderr: total, offset, returned, remaining, scope.

    Examples:
      media list /相册/系统/截图 > /tmp/screenshots_batch1.txt
      media list /相册/系统/截图 --offset 3000 > /tmp/screenshots_batch2.txt
      media list /图库 --type video --format tsv
    """

    static let showHelp = """
    media show

    Usage:
      media show <path>...
      media show --from-file <path-list> [--limit N] [--format text|tsv|jsonl]

    Description:
      Show compact metadata: Path, Size, Created, OCR: true|false, VLM: true|false.
      Full access mode may also show cached Location text.
      Use this to check OCR/VLM cache state before reading expensive text or visual summaries.
      With --from-file, --limit limits how many input paths are read. It is not SDK output truncation.

    Example:
      media show /相册/系统/截图/a.png /相册/系统/截图/b.png
      media show --from-file /tmp/batch1.txt --limit 200 --format tsv
    """

    static let ocrHelp = """
    media show --ocr

    Usage:
      media show --ocr <path>...
      media show --ocr --from-file <path-list> [--limit N]

    Description:
      Print OCR text for media paths.
      Cached OCR is returned for every requested path.
      OCR:false paths are newly OCRed at most 20 per shell run; the rest are listed as skipped.
      This 20-image live OCR budget is shared by the whole shell run.
      Example: if 1000 paths include 500 OCR:true and 500 OCR:false, this returns 500 cached results plus at most 20 new OCR results, then reports 480 skipped.

    Large albums:
      Use media search --ocr for cached OCR keyword or regex filtering across many files.
      Use media show --ocr for selected files whose OCR text you need to inspect directly.
      If OCR is missing, ambiguous, or not enough, inspect selected images with media view.
      With --from-file, --limit limits how many input paths are read. It is not SDK output truncation.

    Output examples:
      media show /图库/a.png /图库/b.png prints metadata records:
        Path: /图库/a.png
        Size: 1179x2556
        Created: 2026-06-01T10:00:00
        OCR: true
        VLM: true

        Path: /图库/b.png
        Size: 1284x2778
        Created: 2026-06-02T10:00:00
        OCR: false
        VLM: false

      media show --ocr /图库/a.png /图库/b.png does not print Path: records. It prints path headings plus OCR text:
        /图库/a.png:
        微信 支付成功
        金额 ¥128.00

        /图库/b.png:
        验证码 123456
        请勿泄露给他人

      media show --ocr /图库/a.png may print only OCR text, with no path heading.
      Do not parse media show --ocr output with ^Path:.

    Command example:
      media show --ocr /相册/系统/截图/a.png /相册/系统/截图/b.png
      media show --ocr --from-file /tmp/selected_for_ocr.txt --limit 20
    """

    static let searchOCRHelp = """
    media search --ocr

    Usage:
      media search --ocr <keyword> <path>...
      media search --ocr <keyword> --from-file <path-list> [--limit N] [--format snippets|paths|jsonl]
      media search --ocr --regex <pattern> <path>...
      media search --ocr --regex <pattern> --from-file <path-list> [--limit N] [--format snippets|paths|jsonl]

    Description:
      Search cached OCR text for media paths and print matching paths with short snippets.
      This command does not perform live OCR. OCR:false paths are counted as uncached and skipped.
      The default mode is case-insensitive keyword search. Use --regex only when regex matching is needed.
      Use --format paths when redirecting matches to a path-list file.
      Use --format jsonl when you need match details for review reasons; each line includes path, source, query_kind, query, match, and snippet.

    Example:
      media search --ocr 支付成功 /相册/系统/截图/a.png /相册/系统/截图/b.png
      media search --ocr --regex '验证码|支付成功|订单完成' /相册/系统/截图/a.png /相册/系统/截图/b.png
      media search --ocr --regex '验证码|支付成功' --from-file /tmp/batch1.txt --format paths > /tmp/matches.txt
      media search --ocr --regex '取件码|已签收' --from-file /tmp/batch1.txt --format jsonl > /tmp/ocr_matches.jsonl
    """

    static let statusHelp = """
    media status

    Usage:
      media status
      media cache status [ocr|vlm|place]

    Description:
      Show the photo-library index state and OCR/VLM/place cache coverage.
      Use this before large classification work instead of scanning the library to guess cache coverage.
    """

    static let vlmHelp = """
    media vlm

    Usage:
      media vlm status

    Description:
      Show global VLM cache and provider state. The first implementation uses a bundled local FastVLM-0.5B stage3 provider when installed. System visual intelligence is reported separately and may be unavailable on devices without Apple Intelligence.
    """

    static let showVLMHelp = """
    media show --vlm

    Usage:
      media show --vlm <path>...
      media show --vlm --from-file <path-list> [--limit N]

    Description:
      Print cached VLM summaries for media paths.
      VLM summaries are natural-language only; they are independent from OCR and do not contain JSON, labels, or kind fields.
      Cached VLM summaries are returned for every requested path.
      VLM:false paths are summarized live at most 3 per shell run when the bundled local model is installed; the rest are listed as skipped.
      The VLM prompt is fixed:
        用简体中文一到两句话描述这张图片的主要内容，总字数不超过50字。不要转写大段文字。
      Search cached summaries with media search --vlm. Search never performs live VLM.
      With --from-file, --limit limits how many input paths are read. It is not SDK output truncation.

    Output example:
      /图库/a.png:
      一张手机支付页面截图，画面中有付款成功提示。

      /图库/b.png:
      一张夜间街景照片，画面中有路灯和车辆。
    """

    static let searchVLMHelp = """
    media search --vlm

    Usage:
      media search --vlm <keyword> <path>...
      media search --vlm <keyword> --from-file <path-list> [--limit N] [--format snippets|paths|jsonl]
      media search --vlm --regex <pattern> <path>...
      media search --vlm --regex <pattern> --from-file <path-list> [--limit N] [--format snippets|paths|jsonl]

    Description:
      Search cached VLM summaries for media paths and print matching paths with short snippets.
      This command does not perform live VLM. VLM:false paths are counted as uncached and skipped.
      The default mode is case-insensitive keyword search. Use --regex only when regex matching is needed.
      Use --format paths when redirecting matches to a path-list file.
      Use --format jsonl when you need match details for review reasons; each line includes path, source, query_kind, query, match, and snippet.

    Example:
      media search --vlm 支付 /相册/系统/截图/a.png /相册/系统/截图/b.png
      media search --vlm --regex '支付|订单' /相册/系统/截图/a.png /相册/系统/截图/b.png
      media search --vlm --regex '支付|订单' --from-file /tmp/batch1.txt --format paths > /tmp/matches.txt
      media search --vlm --regex '物流|订单|截图' --from-file /tmp/batch1.txt --format jsonl > /tmp/vlm_matches.jsonl
    """

    static let viewHelp = """
    media view

    Usage:
      media view <path>...
      media view --from-file <path-list> [--limit 20]

    Description:
      Attach selected images to the model for visual inspection.
      Requires full Photos access mode.
      At most 20 images are sent per command; extra paths are listed as skipped.
      Use this when OCR is missing or uncertain, visual content matters, or the user asks to inspect the image itself.
      With --from-file, --limit limits how many input paths are read before the media-view limit applies.

    Example:
      media view /图库/IMG_0001.PNG /相册/系统/截图/a.png
      media view --from-file /tmp/uncertain_paths.txt --limit 20
    """

    static let askHelp = """
    media ask

    Usage:
      media ask [--message <text>] <path>...
      media ask --from-file <path-list> [--limit 200] [--message <text>]
      media ask --from-jsonl <candidate-jsonl> [--limit 200] [--message <text>]
      media ask ... [--write-selected <path>] [--write-excluded <path>] [--write-skipped <path>]

    Description:
      Ask the user to visually review candidate photos, videos, or Live Photos before you continue.
      It opens a clear preview UI for the user; it is not for sending original media contents to the model.
      Use --message to show the user a short explanation of what these candidates are, what decision you need, and how they can respond.
      The preview starts with all media selected. The user can uncheck items, add a note, then confirm or cancel.
      Output reports confirmed or cancelled, which paths stayed selected, which paths were excluded, the user's note, and lightweight metadata: date, dimensions, OCR cache, and VLM cache.
      With --from-jsonl, each non-empty line is a JSON object with required path and optional title, confidence, basis, matched_terms, risk, and detail. The review UI shows those reason fields under each thumbnail.
      Use --write-selected, --write-excluded, and --write-skipped for large batches; each writes a UTF-8 text file with one path per line, without changing the default stdout shape.
      Use this before risky or preference-sensitive work such as deleting, moving, cleanup albums, high-value checks, or narrowing candidates.
      Treat the user's selection and note as the source of truth for the next step.
      At most 200 media items are previewed per command; extra paths are listed as skipped.

    Example:
      media ask /图库/IMG_0001.PNG /相册/系统/截图/a.png
      media ask --message "我筛出了一批疑似游戏截图。请取消勾选想保留的图片，也可以在备注里告诉我哪些类型以后不要删。" --from-file /tmp/candidates.txt --limit 200
      media ask --message "我筛出了一批疑似物流临时截图，请取消勾选想保留的。" --from-jsonl /tmp/candidates_with_reasons.jsonl --limit 200
      media ask --message "请确认这批候选。" --from-file /tmp/candidates.txt --limit 200 --write-selected /tmp/ask_selected.txt --write-excluded /tmp/ask_excluded.txt --write-skipped /tmp/ask_skipped.txt
    """

    static let statsHelp = """
    media stats

    Usage:
      media stats <scope> --group-by month [--date created|modified] [--type image|video|all] [--format tsv|jsonl]
      media stats <scope> --group-by type [--type image|video|all] [--format tsv|jsonl]

    Description:
      Compute cheap counts from the photo index. Use this instead of find | xargs stat | sort | uniq.

    Examples:
      media stats /相册/系统/截图 --group-by month
      media stats /图库 --group-by type --format jsonl
    """

    static let trashHelp = """
    media trash

    Usage:
      media trash --from-file <path-list> [--limit N]

    Description:
      Move listed photo or video assets to /最近删除 in one batch and print a summary.
      Inputs must be media paths under /图库 or /相册.
      Missing stale paths are skipped and counted, so repeated batch trash commands are safe to rerun.
      Use this instead of xargs rm for approved destructive actions.
    """

    static let restoreHelp = """
    media restore

    Usage:
      media restore --from-file <path-list> [--limit N]

    Description:
      Restore listed paths from /最近删除 in one batch and print a summary.
      Inputs must be paths under /最近删除.
      Missing stale paths are skipped and counted, so repeated batch restore commands are safe to rerun.
    """

    static let help = MSPCommandHelp(
        commandName: "media",
        root: rootHelp,
        topics: [
            "list": listHelp,
            "show": showHelp,
            "show --ocr": ocrHelp,
            "show --vlm": showVLMHelp,
            "status": statusHelp,
            "cache status": statusHelp,
            "vlm": vlmHelp,
            "vlm status": vlmHelp,
            "search --ocr": searchOCRHelp,
            "search --vlm": searchVLMHelp,
            "view": viewHelp,
            "ask": askHelp,
            "stats": statsHelp,
            "trash": trashHelp,
            "restore": restoreHelp
        ],
        topicAliases: [
            "ls": "list",
            "ocr": "show --ocr",
            "show ocr": "show --ocr",
            "cache": "cache status",
            "vlm status": "vlm",
            "show vlm": "show --vlm",
            "search ocr": "search --ocr",
            "search vlm": "search --vlm",
            "grep --ocr": "search --ocr",
            "grep ocr": "search --ocr",
            "grep --vlm": "search --vlm",
            "grep vlm": "search --vlm"
        ]
    )
}
