/**
 * Country choices on the sign-up forms: the registries' countries first, then a short list of
 * frequent applicant countries. The full ISO 3166 list is loaded with the data files in Step 3.4
 * (RULING NEEDED: source for country names in Arabic — MoET list or ISO Arabic short names).
 */
export const COUNTRIES: Array<{ code: string; en: string; ar: string }> = [
  { code: "AE", en: "United Arab Emirates", ar: "الإمارات العربية المتحدة" },
  { code: "SA", en: "Saudi Arabia", ar: "المملكة العربية السعودية" },
  { code: "OM", en: "Oman", ar: "عُمان" },
  { code: "KW", en: "Kuwait", ar: "الكويت" },
  { code: "QA", en: "Qatar", ar: "قطر" },
  { code: "BH", en: "Bahrain", ar: "البحرين" },
  { code: "GB", en: "United Kingdom", ar: "المملكة المتحدة" },
  { code: "US", en: "United States", ar: "الولايات المتحدة" },
  { code: "DE", en: "Germany", ar: "ألمانيا" },
  { code: "FR", en: "France", ar: "فرنسا" },
  { code: "IT", en: "Italy", ar: "إيطاليا" },
  { code: "ES", en: "Spain", ar: "إسبانيا" },
  { code: "NL", en: "Netherlands", ar: "هولندا" },
  { code: "TR", en: "Türkiye", ar: "تركيا" },
  { code: "IN", en: "India", ar: "الهند" },
  { code: "CN", en: "China", ar: "الصين" },
  { code: "EG", en: "Egypt", ar: "مصر" },
  { code: "JO", en: "Jordan", ar: "الأردن" },
  { code: "LB", en: "Lebanon", ar: "لبنان" },
  { code: "MA", en: "Morocco", ar: "المغرب" },
  { code: "PK", en: "Pakistan", ar: "باكستان" },
  { code: "SG", en: "Singapore", ar: "سنغافورة" },
  { code: "JP", en: "Japan", ar: "اليابان" },
  { code: "KR", en: "South Korea", ar: "كوريا الجنوبية" },
  { code: "CH", en: "Switzerland", ar: "سويسرا" },
  { code: "AU", en: "Australia", ar: "أستراليا" },
  { code: "CA", en: "Canada", ar: "كندا" },
];

/** Registries an agency may hold a licence at (first launch + second wave; from registry.registry). */
export const LICENCE_REGISTRIES: Array<{ code: string; en: string; ar: string }> = [
  { code: "AE", en: "UAE — Ministry of Economy and Tourism", ar: "الإمارات — وزارة الاقتصاد والسياحة" },
  { code: "SA", en: "Saudi Arabia — SAIP", ar: "السعودية — الهيئة السعودية للملكية الفكرية" },
  { code: "OM", en: "Oman — Ministry of Commerce, Industry and Investment Promotion", ar: "عُمان — وزارة التجارة والصناعة وترويج الاستثمار" },
  { code: "KW", en: "Kuwait — Ministry of Commerce and Industry", ar: "الكويت — وزارة التجارة والصناعة" },
  { code: "QA", en: "Qatar — Ministry of Commerce and Industry", ar: "قطر — وزارة التجارة والصناعة" },
  { code: "BH", en: "Bahrain — Ministry of Industry and Commerce", ar: "البحرين — وزارة الصناعة والتجارة" },
  { code: "GB", en: "United Kingdom — UK IPO", ar: "المملكة المتحدة — مكتب الملكية الفكرية" },
  { code: "EM", en: "European Union — EUIPO", ar: "الاتحاد الأوروبي — مكتب الملكية الفكرية للاتحاد الأوروبي" },
  { code: "US", en: "United States — USPTO", ar: "الولايات المتحدة — مكتب البراءات والعلامات التجارية" },
  { code: "TR", en: "Türkiye — TÜRKPATENT", ar: "تركيا — المكتب التركي للبراءات والعلامات" },
  { code: "IN", en: "India — Trade Marks Registry", ar: "الهند — سجل العلامات التجارية" },
  { code: "CN", en: "China — CNIPA", ar: "الصين — الإدارة الوطنية للملكية الفكرية" },
  { code: "EG", en: "Egypt — Trademark Office", ar: "مصر — مكتب العلامات التجارية" },
  { code: "JO", en: "Jordan — Ministry of Industry, Trade and Supply", ar: "الأردن — وزارة الصناعة والتجارة والتموين" },
];
