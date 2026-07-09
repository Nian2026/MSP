# Third-Party Notices

MSPChatUI is licensed under the repository Apache-2.0 license.

The Default renderer packages browser runtime assets copied from the ignored
Readex-mode reference snapshot. The release gate verifies the visible notice
files and the publishable Markstream bundle license audit fixture.

## Included Notice Files

| Asset family | Notice file |
| --- | --- |
| diff2html | `Renderers/Default/runtime/assets/Math/diff2html-LICENSE.md` |
| highlight.js | `Renderers/Default/runtime/assets/Math/highlightjs-LICENSE.txt` |
| Prettier | `Renderers/Default/runtime/assets/Math/prettier-LICENSE.txt` |
| d3 | `Renderers/Default/runtime/assets/KnowledgeMap/d3-LICENSE.txt` |
| markmap-view | `Renderers/Default/runtime/assets/KnowledgeMap/markmap-view-LICENSE.txt` |

## Markstream Bundle Audit

`Renderers/Default/runtime/assets/Math/readex-markstream-sdk.js` is audited
against:

`Conformance/fixtures/markstream-bundle-license-audit.json`

Current license families in that fixture:

| License | Package count |
| --- | ---: |
| MIT | 130 |
| ISC | 3 |
| MPL-2.0 OR Apache-2.0 | 1 |
| BSD-2-Clause | 1 |
| BSD-3-Clause | 1 |

`Conformance/scripts/license-audit.cjs` fails if the shipped bundle hash changes,
if any package has missing license metadata, or if any unapproved license family
appears.
