-- 0099 — Egypt's gazette read by its printed labels (Founder, 26 Nov 2026: Egypt continues in testing and
-- learning; nothing of it is live until he confirms).
--
-- The part of gazette 1035 that publishes accepted marks was received by e-mail and examined: a word-processor
-- file with the text inside, one mark to a page. It is a table whose labels stand beside the MIDDLE of their
-- values, so a value's lines stand above its label as well as under it: the "centred" layout of the labels
-- reader tells them by their place. The class numbers stand alone on a line above the goods. The office prints
-- no wording of the mark, no agent and no description: the mark is its picture. The office's watermark is on
-- every page and is not the mark's picture (read.picture.not).
-- No `accept`: every Egyptian mark read waits for a person. Egypt's re-use stays "pilot test only": every page
-- of the gazette carries a notice against copying and re-publication, to be settled before anything is shown.
BEGIN;

UPDATE watch.publication_source s
   SET fetch_spec = jsonb_set(s.fetch_spec, '{read}', $eg$
{
  "method": "labels",
  "prepare": "arabic_order",
  "forms": [
    {
      "key": "accepted",
      "kind": "marks",
      "layout": "centred",
      "top": 60,
      "bottom": 790,
      "start": "العلامة",
      "start_exact": true,
      "title": "جريدةالعلاماتالتجارية",
      "labels": [
        {
          "field": "number",
          "label": "قدم عنها طلب رقم:"
        },
        {
          "field": "filed",
          "label": "بتاريخ:"
        },
        {
          "field": "applicant",
          "label": "إسم طالب التسجيل:"
        },
        {
          "field": "address",
          "label": "العنوان:"
        },
        {
          "field": "goods",
          "label": "فئات العلامة:"
        },
        {
          "field": "conditions",
          "label": "الاشتراطات",
          "top": true
        }
      ],
      "lines": [
        {
          "pattern": "^\\d{1,2}(-\\d{1,2})*$",
          "field": "classes",
          "when": [
            "goods"
          ]
        }
      ]
    }
  ],
  "observed": "26 Nov 2026, gazette 1035 (the part that publishes accepted marks, 434 pages): made with a word processor, the text inside; one mark to a page over the office's watermark, long goods running on to a page without a heading; a table whose labels stand beside the middle of their values (the conditions label on the first line of its value); the class numbers alone on a line above the goods. No wording of the mark, no agent and no description are printed. Read by rules: 426 marks, all complete, numbers all different.",
  "picture": {
    "min": 24,
    "not": [
      [
        1600,
        1383
      ]
    ]
  }
}
  $eg$::jsonb, true), updated_at = now()
  FROM registry.registry g
 WHERE g.id = s.registry_id AND g.code = 'EG' AND s.stream = 'national_bulletin';

COMMIT;
