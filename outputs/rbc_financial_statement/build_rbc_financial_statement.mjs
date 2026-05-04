import fs from "node:fs/promises";
import path from "node:path";
import * as pdfjsLib from "pdfjs-dist/legacy/build/pdf.mjs";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const repoRoot = "C:/Git Local Repos/forge_flow_demo";
const sourceFolder = path.join(repoRoot, "docs", "Rbc statements");
const outputDir = path.join(repoRoot, "outputs", "rbc_financial_statement");
const outputPath = path.join(
  outputDir,
  "rbc_cash_basis_financial_statement_sep2025_mar2026.xlsx",
);

const monthNames = {
  January: 0,
  February: 1,
  March: 2,
  April: 3,
  May: 4,
  June: 5,
  July: 6,
  August: 7,
  September: 8,
  October: 9,
  November: 10,
  December: 11,
};

const monthAbbr = {
  Jan: 0,
  Feb: 1,
  Mar: 2,
  Apr: 3,
  May: 4,
  Jun: 5,
  Jul: 6,
  Aug: 7,
  Sep: 8,
  Oct: 9,
  Nov: 10,
  Dec: 11,
};

const monthShort = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];

function parseMoney(value) {
  return Number(String(value).replace(/[$,]/g, ""));
}

function round2(value) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function parseLongDate(text) {
  const match = text.match(/^([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})$/);
  if (!match) throw new Error(`Unable to parse date: ${text}`);
  return new Date(Date.UTC(Number(match[3]), monthNames[match[1]], Number(match[2])));
}

function dateOnly(date) {
  return date.toISOString().slice(0, 10);
}

function monthLabel(date) {
  return `${monthShort[date.getUTCMonth()]} ${date.getUTCFullYear()}`;
}

function inferTransactionDate(day, mon, start, end) {
  const month = monthAbbr[mon];
  const candidates = [
    new Date(Date.UTC(start.getUTCFullYear(), month, Number(day))),
    new Date(Date.UTC(end.getUTCFullYear(), month, Number(day))),
  ];
  const hit = candidates.find((candidate) => candidate >= start && candidate <= end);
  return hit ?? candidates[0];
}

function colName(index) {
  let n = index;
  let out = "";
  while (n > 0) {
    const rem = (n - 1) % 26;
    out = String.fromCharCode(65 + rem) + out;
    n = Math.floor((n - 1) / 26);
  }
  return out;
}

function rangeAddress(row, col, rows = 1, cols = 1) {
  const start = `${colName(col)}${row}`;
  const end = `${colName(col + cols - 1)}${row + rows - 1}`;
  return start === end ? start : `${start}:${end}`;
}

function writeValues(sheet, row, col, values) {
  if (!values.length || !values[0].length) return;
  sheet.getRange(rangeAddress(row, col, values.length, values[0].length)).values = values;
}

function writeFormulas(sheet, row, col, formulas) {
  if (!formulas.length || !formulas[0].length) return;
  sheet.getRange(rangeAddress(row, col, formulas.length, formulas[0].length)).formulas = formulas;
}

function applyBaseSheetStyle(sheet) {
  sheet.showGridLines = false;
  sheet.getRange("A:K").format.font = { name: "Aptos", size: 10, color: "#1F2937" };
}

function styleTitle(sheet, range, titleFill = "#1F4E79") {
  const target = sheet.getRange(range);
  target.merge();
  target.format.fill = titleFill;
  target.format.font = { color: "#FFFFFF", bold: true, size: 16 };
  target.format.horizontalAlignment = "center";
  target.format.rowHeightPx = 34;
}

function styleSectionHeader(sheet, range, fill = "#D9EAF7") {
  const target = sheet.getRange(range);
  target.format.fill = fill;
  target.format.font = { bold: true, color: "#17365D" };
  target.format.borders = { preset: "outside", style: "thin", color: "#A6BDD7" };
}

function styleTable(sheet, headerRange, bodyRange) {
  const header = sheet.getRange(headerRange);
  header.format.fill = "#244062";
  header.format.font = { color: "#FFFFFF", bold: true };
  header.format.horizontalAlignment = "center";
  header.format.wrapText = true;
  header.format.rowHeightPx = 34;
  const body = sheet.getRange(bodyRange);
  body.format.borders = { preset: "all", style: "thin", color: "#D9E2F3" };
  body.format.rowHeightPx = 24;
}

function styleKpi(sheet, range) {
  const target = sheet.getRange(range);
  target.format.fill = "#F2F7FB";
  target.format.borders = { preset: "outside", style: "thin", color: "#B7C9DD" };
  target.format.rowHeightPx = 28;
}

function categorize(description) {
  if (/^Monthly fee/i.test(description)) {
    return { category: "Bank fees", detail: "" };
  }
  if (/^e-Transfer sent/i.test(description)) {
    return {
      category: "e-Transfer sent",
      detail: description.replace(/^e-Transfer sent\s*/i, "").trim(),
    };
  }
  if (/^Misc Payment/i.test(description)) {
    return {
      category: "Receipts - Misc Payment",
      detail: description.replace(/^Misc Payment\s*/i, "").trim(),
    };
  }
  return { category: "Other", detail: "" };
}

async function extractPdfText(filePath) {
  const data = new Uint8Array(await fs.readFile(filePath));
  const doc = await pdfjsLib.getDocument({
    data,
    useWorkerFetch: false,
    isEvalSupported: false,
    disableFontFace: true,
  }).promise;

  const pages = [];
  for (let pageNumber = 1; pageNumber <= doc.numPages; pageNumber += 1) {
    const page = await doc.getPage(pageNumber);
    const content = await page.getTextContent();
    pages.push(content.items.map((item) => item.str).join(" "));
  }
  return { text: pages.join("\n"), pages: doc.numPages };
}

function parseStatement(fileName, text, pageCount) {
  const period = text.match(
    /Business Account Statement\s+([A-Za-z]+ \d{1,2}, \d{4}) to ([A-Za-z]+ \d{1,2}, \d{4})/,
  );
  const opening = text.match(/Opening balance on [A-Za-z]+ \d{1,2}, \d{4}\s+\$([0-9,]+\.\d{2})/);
  const deposits = text.match(/Total deposits & credits \((\d+)\)\s+\+\s+([0-9,]+\.\d{2})/);
  const debits = text.match(/Total cheques & debits \((\d+)\)\s+-\s+([0-9,]+\.\d{2})/);
  const closing = text.match(/Closing balance on [A-Za-z]+ \d{1,2}, \d{4}\s+=\s+\$([0-9,]+\.\d{2})/);
  const account = text.match(/Account number:\s+(\d+)\s+([0-9-]+)/);
  const company = text.match(/\b\d{5}\s+\d{5}\s+(\d{5}\s+[A-Z0-9 &'().,-]+?LTD\.)\s+9 PICEA/);
  if (!period || !opening || !deposits || !debits || !closing) {
    throw new Error(`Missing statement summary data in ${fileName}`);
  }

  const periodStart = parseLongDate(period[1]);
  const periodEnd = parseLongDate(period[2]);
  const statement = {
    fileName,
    pageCount,
    company: company?.[1] ?? "NEWFOUNDLAND & LABRADOR LTD.",
    branch: account?.[1] ?? "",
    accountMasked: account ? `${account[1]} ***-***-${account[2].slice(-1)}` : "Masked",
    periodStart,
    periodEnd,
    statementLabel: `${dateOnly(periodStart)} to ${dateOnly(periodEnd)}`,
    month: monthLabel(periodEnd),
    openingBalance: parseMoney(opening[1]),
    depositCount: Number(deposits[1]),
    totalDeposits: parseMoney(deposits[2]),
    debitCount: Number(debits[1]),
    totalDebits: parseMoney(debits[2]),
    closingBalance: parseMoney(closing[1]),
    transactions: [],
  };

  let activity = text.split("Account Activity Details")[1] ?? "";
  activity = activity.replace(/\s+/g, " ");
  const txRegex =
    /(\d{2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(.+?)(?=\s+\d{2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+|Closing balance)/g;
  let previousBalance = statement.openingBalance;
  for (const match of activity.matchAll(txRegex)) {
    const [, day, mon, body] = match;
    const amountMatches = [...body.matchAll(/-?\d{1,3}(?:,\d{3})*\.\d{2}/g)];
    if (amountMatches.length < 2) continue;
    const balanceMatch = amountMatches[amountMatches.length - 1];
    const amountMatch = amountMatches[amountMatches.length - 2];
    const endingBalance = parseMoney(balanceMatch[0]);
    const statedAmount = parseMoney(amountMatch[0]);
    const description = body.slice(0, amountMatch.index).trim();
    const delta = round2(endingBalance - previousBalance);
    const debit = delta < 0 ? round2(Math.abs(delta)) : 0;
    const credit = delta > 0 ? round2(delta) : 0;
    const { category, detail } = categorize(description);
    const transactionDate = inferTransactionDate(day, mon, periodStart, periodEnd);
    const amountDifference = round2(Math.abs(delta) - statedAmount);

    statement.transactions.push({
      date: transactionDate,
      statementLabel: statement.statementLabel,
      description,
      detail,
      category,
      debit,
      credit,
      netCashFlow: round2(credit - debit),
      balance: endingBalance,
      sourceFile: fileName,
      parseNote: Math.abs(amountDifference) <= 0.01 ? "" : `Amount variance ${amountDifference.toFixed(2)}`,
    });
    previousBalance = endingBalance;
  }

  return statement;
}

async function loadStatements() {
  const files = (await fs.readdir(sourceFolder)).filter((file) => file.toLowerCase().endsWith(".pdf"));
  const statements = [];
  for (const file of files) {
    const { text, pages } = await extractPdfText(path.join(sourceFolder, file));
    statements.push(parseStatement(file, text, pages));
  }
  statements.sort((a, b) => a.periodStart - b.periodStart);
  return statements;
}

function buildWorkbook(statements) {
  const workbook = Workbook.create();
  const summary = workbook.worksheets.add("Summary");
  const monthly = workbook.worksheets.add("Monthly Statement");
  const transactions = workbook.worksheets.add("Transactions");
  const checks = workbook.worksheets.add("Checks");
  const sources = workbook.worksheets.add("Sources");

  for (const sheet of [summary, monthly, transactions, checks, sources]) {
    applyBaseSheetStyle(sheet);
  }

  const allTransactions = statements.flatMap((statement) => statement.transactions);
  const firstStatement = statements[0];
  const lastStatement = statements[statements.length - 1];
  const companyName = firstStatement.company;
  const accountMasked = firstStatement.accountMasked;
  const sourcePeriod = `${dateOnly(firstStatement.periodStart)} to ${dateOnly(lastStatement.periodEnd)}`;
  const today = new Date();

  buildMonthly(monthly, statements);
  buildTransactions(transactions, allTransactions);
  buildSources(sources, statements, companyName, accountMasked, sourcePeriod);
  buildChecks(checks, statements);
  buildSummary(summary, statements, companyName, accountMasked, sourcePeriod, today);

  workbook.recalculate();
  return workbook;
}

function buildSummary(sheet, statements, companyName, accountMasked, sourcePeriod, generatedAt) {
  writeValues(sheet, 1, 1, [["Cash-Basis Financial Statement from RBC Statements"]]);
  styleTitle(sheet, "A1:K1");

  writeValues(sheet, 3, 1, [
    ["Company", companyName, "", "Statement Basis", "Cash basis from RBC bank statements", "", "Source Period", sourcePeriod],
    ["Account", accountMasked, "", "Generated", generatedAt, "", "Review Status", ""],
  ]);
  writeFormulas(sheet, 4, 8, [[`=IF(COUNTIF(Checks!G:G,"Review")=0,"OK","Review")`]]);
  for (const range of ["B3:C3", "E3:F3", "H3:K3", "B4:C4", "E4:F4", "H4:K4"]) {
    sheet.getRange(range).merge();
  }
  sheet.getRange("A3:K4").format.borders = { preset: "all", style: "thin", color: "#D9E2F3" };
  sheet.getRange("A3:A4").format.font = { bold: true };
  sheet.getRange("D3:D4").format.font = { bold: true };
  sheet.getRange("G3:G4").format.font = { bold: true };
  sheet.getRange("E4").format.numberFormat = "yyyy-mm-dd";

  writeValues(sheet, 6, 1, [
    ["Beginning Cash"],
    ["Total Receipts"],
    ["Total Payments"],
    ["Net Cash Movement"],
    ["Ending Cash"],
  ]);
  writeFormulas(sheet, 6, 2, [
    [`='Monthly Statement'!C6`],
    [`=SUM('Monthly Statement'!D6:D${5 + statements.length})`],
    [`=SUM('Monthly Statement'!E6:E${5 + statements.length})`],
    [`=B7-B8`],
    [`='Monthly Statement'!G${5 + statements.length}`],
  ]);
  writeValues(sheet, 6, 4, [
    ["Receipts Count"],
    ["Debit Count"],
    ["Bank Fees"],
    ["e-Transfer Sent"],
    ["Statements Used"],
  ]);
  writeFormulas(sheet, 6, 5, [
    [`=SUM('Monthly Statement'!H6:H${5 + statements.length})`],
    [`=SUM('Monthly Statement'!I6:I${5 + statements.length})`],
    [`=SUMIF(Transactions!E:E,"Bank fees",Transactions!F:F)`],
    [`=SUMIF(Transactions!E:E,"e-Transfer sent",Transactions!F:F)`],
    [`=COUNTA(Sources!A6:A${5 + statements.length})`],
  ]);

  for (const range of ["A6:B10", "D6:E10"]) {
    styleKpi(sheet, range);
  }
  sheet.getRange("A6:A10").format.font = { bold: true, color: "#17365D" };
  sheet.getRange("D6:D10").format.font = { bold: true, color: "#17365D" };
  sheet.getRange("B6:B10").format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange("E8:E9").format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange("E6:E7").format.numberFormat = "#,##0";
  sheet.getRange("E10").format.numberFormat = "#,##0";

  writeValues(sheet, 12, 1, [["Cash-Basis Statement of Receipts and Payments", "", "", ""]]);
  styleSectionHeader(sheet, "A12:D12");
  writeValues(sheet, 13, 1, [
    ["Line Item", "Amount ($)", "Source", "Notes"],
    ["Receipts / deposits from bank activity", null, "Transactions", "Credits shown in RBC statements"],
    ["Bank service charges", null, "Transactions", "Monthly RBC account fees"],
    ["e-Transfer payments sent", null, "Transactions", "Cash outflows from e-Transfers"],
    ["Total payments / cash outflows", null, "Formula", "Bank fees plus e-Transfers"],
    ["Net cash income / increase in cash", null, "Formula", "Receipts less payments"],
  ]);
  writeFormulas(sheet, 14, 2, [
    [`=SUMIF(Transactions!E:E,"Receipts - Misc Payment",Transactions!G:G)`],
    [`=-SUMIF(Transactions!E:E,"Bank fees",Transactions!F:F)`],
    [`=-SUMIF(Transactions!E:E,"e-Transfer sent",Transactions!F:F)`],
    [`=SUM(B15:B16)`],
    [`=B14+B17`],
  ]);
  styleTable(sheet, "A13:D13", "A14:D18");
  sheet.getRange("B14:B18").format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange("D14:D18").format.wrapText = true;

  writeValues(sheet, 21, 1, [["Statement of Cash Position", "", "", ""]]);
  styleSectionHeader(sheet, "A21:D21");
  writeValues(sheet, 22, 1, [
    ["Line Item", "Amount ($)", "Source", "Notes"],
    ["Cash at beginning of period", null, "Monthly Statement", "Opening balance from first statement"],
    ["Net cash movement", null, "Formula", "Receipts less payments"],
    ["Cash at end of period", null, "Monthly Statement", "Closing balance from final statement"],
  ]);
  writeFormulas(sheet, 23, 2, [
    [`=B6`],
    [`=B9`],
    [`=B10`],
  ]);
  styleTable(sheet, "A22:D22", "A23:D25");
  sheet.getRange("B23:B25").format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange("D23:D25").format.wrapText = true;

  writeValues(sheet, 28, 1, [["Chart Data", "", "", ""]]);
  styleSectionHeader(sheet, "A28:D28");
  writeValues(sheet, 29, 1, [["Statement Month", "Receipts", "Payments", "Net Movement"]]);
  const chartRows = statements.map((statement, index) => [
    statement.month,
    `='Monthly Statement'!D${6 + index}`,
    `=-'Monthly Statement'!E${6 + index}`,
    `='Monthly Statement'!F${6 + index}`,
  ]);
  writeValues(sheet, 30, 1, chartRows.map((row) => [row[0], null, null, null]));
  writeFormulas(sheet, 30, 2, chartRows.map((row) => row.slice(1)));
  styleTable(sheet, "A29:D29", `A30:D${29 + statements.length}`);
  sheet.getRange(`B30:D${29 + statements.length}`).format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";

  const chartRange = sheet.getRange(`A29:D${29 + statements.length}`);
  const chart = sheet.charts.add("ColumnClustered", chartRange, "Auto");
  chart.title.text = "Monthly Cash Activity";
  chart.setPosition(sheet.getRange("F12:K27"));
  chart.width = 520;
  chart.height = 320;
  chart.hasLegend = true;
  chart.legend = { position: "bottom", textStyle: { fontSize: 9 } };
  chart.yAxis = { title: { text: "CAD $" }, majorGridlines: { fill: "#D9E2F3", style: "solid", width: 0.75 } };

  writeValues(sheet, 38, 1, [
    [
      "Important note",
      "This workbook is a factual cash-basis summary of the RBC bank statements provided. It is not an accrual financial statement, tax filing, compilation, review, or audit.",
    ],
  ]);
  sheet.getRange("B38:E40").merge();
  sheet.getRange("A38:E40").format.fill = "#FFF2CC";
  sheet.getRange("A38:E40").format.borders = { preset: "outside", style: "thin", color: "#D6B656" };
  sheet.getRange("A38").format.font = { bold: true, color: "#7F6000" };
  sheet.getRange("B38").format.wrapText = true;
  sheet.getRange("A38:E40").format.rowHeightPx = 28;

  sheet.getRange("A:K").format.autofitColumns();
  sheet.getRange("A:A").format.columnWidthPx = 300;
  sheet.getRange("B:B").format.columnWidthPx = 200;
  sheet.getRange("C:C").format.columnWidthPx = 155;
  sheet.getRange("D:D").format.columnWidthPx = 205;
  sheet.getRange("E:E").format.columnWidthPx = 190;
  sheet.getRange("F:F").format.columnWidthPx = 90;
  sheet.getRange("G:G").format.columnWidthPx = 135;
  sheet.getRange("H:K").format.columnWidthPx = 95;
}

function buildMonthly(sheet, statements) {
  writeValues(sheet, 1, 1, [["Monthly Source Statement Rollforward"]]);
  styleTitle(sheet, "A1:J1");
  writeValues(sheet, 3, 1, [["Each row ties to one RBC PDF statement. Debits are presented as positive outflows."]]);
  sheet.getRange("A3:J3").merge();
  sheet.getRange("A3:J3").format.fill = "#F2F7FB";
  sheet.getRange("A3:J3").format.font = { italic: true, color: "#44546A" };

  writeValues(sheet, 5, 1, [[
    "Source File",
    "Statement Period",
    "Opening Balance",
    "Deposits & Credits",
    "Cheques & Debits",
    "Net Movement",
    "Closing Balance",
    "Deposit Count",
    "Debit Count",
    "Rollforward Difference",
  ]]);

  const rows = statements.map((statement) => [
    statement.fileName,
    statement.statementLabel,
    statement.openingBalance,
    statement.totalDeposits,
    statement.totalDebits,
    null,
    statement.closingBalance,
    statement.depositCount,
    statement.debitCount,
    null,
  ]);
  writeValues(sheet, 6, 1, rows);
  writeFormulas(
    sheet,
    6,
    6,
    statements.map((_, index) => [[`=D${6 + index}-E${6 + index}`]].flat()),
  );
  writeFormulas(
    sheet,
    6,
    10,
    statements.map((_, index) => [[`=ROUND(C${6 + index}+D${6 + index}-E${6 + index}-G${6 + index},2)`]].flat()),
  );

  styleTable(sheet, "A5:J5", `A6:J${5 + statements.length}`);
  sheet.freezePanes.freezeRows(5);
  sheet.getRange(`C6:G${5 + statements.length}`).format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange(`J6:J${5 + statements.length}`).format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange(`H6:I${5 + statements.length}`).format.numberFormat = "#,##0";
  sheet.getRange("A:A").format.columnWidthPx = 140;
  sheet.getRange("B:B").format.columnWidthPx = 200;
  sheet.getRange("C:J").format.columnWidthPx = 118;
}

function buildTransactions(sheet, allTransactions) {
  writeValues(sheet, 1, 1, [["Transaction Detail Extracted from RBC Statements"]]);
  styleTitle(sheet, "A1:K1");
  writeValues(sheet, 3, 1, [["Debits and credits are classified from the running balance movement in each statement."]]);
  sheet.getRange("A3:K3").merge();
  sheet.getRange("A3:K3").format.fill = "#F2F7FB";
  sheet.getRange("A3:K3").format.font = { italic: true, color: "#44546A" };

  writeValues(sheet, 5, 1, [[
    "Date",
    "Statement Period",
    "Description",
    "Detail",
    "Category",
    "Debit ($)",
    "Credit ($)",
    "Net Cash Flow",
    "Balance ($)",
    "Source File",
    "Parse Note",
  ]]);

  const rows = allTransactions.map((transaction) => [
    transaction.date,
    transaction.statementLabel,
    transaction.description,
    transaction.detail,
    transaction.category,
    transaction.debit,
    transaction.credit,
    null,
    transaction.balance,
    transaction.sourceFile,
    transaction.parseNote,
  ]);
  writeValues(sheet, 6, 1, rows);
  writeFormulas(
    sheet,
    6,
    8,
    allTransactions.map((_, index) => [[`=G${6 + index}-F${6 + index}`]].flat()),
  );

  const lastRow = 5 + allTransactions.length;
  styleTable(sheet, "A5:K5", `A6:K${lastRow}`);
  sheet.freezePanes.freezeRows(5);
  sheet.freezePanes.freezeColumns(2);
  sheet.getRange(`A6:A${lastRow}`).format.numberFormat = "yyyy-mm-dd";
  sheet.getRange(`F6:I${lastRow}`).format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange(`C6:E${lastRow}`).format.wrapText = false;
  sheet.getRange("A:A").format.columnWidthPx = 95;
  sheet.getRange("B:B").format.columnWidthPx = 200;
  sheet.getRange("C:C").format.columnWidthPx = 240;
  sheet.getRange("D:D").format.columnWidthPx = 160;
  sheet.getRange("E:E").format.columnWidthPx = 185;
  sheet.getRange("F:I").format.columnWidthPx = 115;
  sheet.getRange("J:J").format.columnWidthPx = 130;
  sheet.getRange("K:K").format.columnWidthPx = 140;
}

function buildSources(sheet, statements, companyName, accountMasked, sourcePeriod) {
  writeValues(sheet, 1, 1, [["Sources and Basis"]]);
  styleTitle(sheet, "A1:I1");
  writeValues(sheet, 3, 1, [
    ["Company", companyName, "", "Account", accountMasked, "", "Source Period", sourcePeriod],
  ]);
  for (const range of ["B3:C3", "E3:F3", "H3:I3"]) {
    sheet.getRange(range).merge();
  }
  sheet.getRange("A3:I3").format.borders = { preset: "all", style: "thin", color: "#D9E2F3" };
  sheet.getRange("A3").format.font = { bold: true };
  sheet.getRange("D3").format.font = { bold: true };
  sheet.getRange("G3").format.font = { bold: true };

  writeValues(sheet, 5, 1, [[
    "Source File",
    "PDF Pages",
    "Statement Period",
    "Opening Balance",
    "Deposits & Credits",
    "Cheques & Debits",
    "Closing Balance",
    "Account Masked",
    "Notes",
  ]]);
  writeValues(
    sheet,
    6,
    1,
    statements.map((statement) => [
      statement.fileName,
      statement.pageCount,
      statement.statementLabel,
      statement.openingBalance,
      statement.totalDeposits,
      statement.totalDebits,
      statement.closingBalance,
      statement.accountMasked,
      "RBC PDF in docs/Rbc statements.",
    ]),
  );
  styleTable(sheet, "A5:I5", `A6:I${5 + statements.length}`);
  sheet.getRange(`D6:G${5 + statements.length}`).format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange("A:A").format.columnWidthPx = 140;
  sheet.getRange("B:B").format.columnWidthPx = 80;
  sheet.getRange("C:C").format.columnWidthPx = 220;
  sheet.getRange("D:G").format.columnWidthPx = 120;
  sheet.getRange("H:H").format.columnWidthPx = 130;
  sheet.getRange("I:I").format.columnWidthPx = 330;
  sheet.getRange("I:I").format.wrapText = true;

  const noteStart = 8 + statements.length;
  writeValues(sheet, noteStart, 1, [
    ["Basis Notes"],
    ["1. This workbook summarizes cash activity only, using the bank statements as the source."],
    ["2. It does not classify accrual revenue, receivables, payables, taxes, depreciation, or non-bank assets/liabilities."],
    ["3. Source account details are masked in this workbook; refer to original PDFs for complete bank identifiers."],
  ]);
  sheet.getRange(`A${noteStart}:I${noteStart}`).merge();
  styleSectionHeader(sheet, `A${noteStart}:I${noteStart}`);
  sheet.getRange(`A${noteStart + 1}:I${noteStart + 3}`).merge(true);
  sheet.getRange(`A${noteStart + 1}:I${noteStart + 3}`).format.wrapText = true;
}

function buildChecks(sheet, statements) {
  writeValues(sheet, 1, 1, [["Reconciliation Checks"]]);
  styleTitle(sheet, "A1:H1");
  writeValues(sheet, 3, 1, [["Checks compare extracted transaction activity to the statement summaries. Status should be OK before using outputs."]]);
  sheet.getRange("A3:H3").merge();
  sheet.getRange("A3:H3").format.fill = "#F2F7FB";
  sheet.getRange("A3:H3").format.font = { italic: true, color: "#44546A" };
  writeValues(sheet, 5, 1, [["Check Group", "Source File", "Check", "Actual", "Expected", "Difference", "Status", "Notes"]]);

  const checkRows = [];
  for (let i = 0; i < statements.length; i += 1) {
    const monthlyRow = 6 + i;
    checkRows.push([
      "Statement rollforward",
      `='Monthly Statement'!A${monthlyRow}`,
      "Opening + credits - debits = closing",
      `='Monthly Statement'!C${monthlyRow}+'Monthly Statement'!D${monthlyRow}-'Monthly Statement'!E${monthlyRow}`,
      `='Monthly Statement'!G${monthlyRow}`,
      `=ROUND(D${6 + checkRows.length}-E${6 + checkRows.length},2)`,
      `=IF(ABS(F${6 + checkRows.length})<=0.01,"OK","Review")`,
      "",
    ]);
    checkRows.push([
      "Transaction credits tie-out",
      `='Monthly Statement'!A${monthlyRow}`,
      "Transaction credits = statement deposits",
      `=SUMIF(Transactions!J:J,B${6 + checkRows.length},Transactions!G:G)`,
      `='Monthly Statement'!D${monthlyRow}`,
      `=ROUND(D${6 + checkRows.length}-E${6 + checkRows.length},2)`,
      `=IF(ABS(F${6 + checkRows.length})<=0.01,"OK","Review")`,
      "",
    ]);
    checkRows.push([
      "Transaction debits tie-out",
      `='Monthly Statement'!A${monthlyRow}`,
      "Transaction debits = statement debits",
      `=SUMIF(Transactions!J:J,B${6 + checkRows.length},Transactions!F:F)`,
      `='Monthly Statement'!E${monthlyRow}`,
      `=ROUND(D${6 + checkRows.length}-E${6 + checkRows.length},2)`,
      `=IF(ABS(F${6 + checkRows.length})<=0.01,"OK","Review")`,
      "",
    ]);
    if (i > 0) {
      checkRows.push([
        "Statement continuity",
        `='Monthly Statement'!A${monthlyRow}`,
        "Opening balance = prior closing balance",
        `='Monthly Statement'!C${monthlyRow}`,
        `='Monthly Statement'!G${monthlyRow - 1}`,
        `=ROUND(D${6 + checkRows.length}-E${6 + checkRows.length},2)`,
        `=IF(ABS(F${6 + checkRows.length})<=0.01,"OK","Review")`,
        "",
      ]);
    }
  }

  writeValues(sheet, 6, 1, checkRows.map((row) => row.map((value, index) => (index === 1 || index >= 3 && index <= 6 ? null : value))));
  writeFormulas(
    sheet,
    6,
    2,
    checkRows.map((row) => [row[1]]),
  );
  writeFormulas(
    sheet,
    6,
    4,
    checkRows.map((row) => row.slice(3, 7)),
  );
  const lastRow = 5 + checkRows.length;
  styleTable(sheet, "A5:H5", `A6:H${lastRow}`);
  sheet.freezePanes.freezeRows(5);
  sheet.getRange(`D6:F${lastRow}`).format.numberFormat = "$#,##0.00;[Red]($#,##0.00);-";
  sheet.getRange(`G6:G${lastRow}`).conditionalFormats.add("containsText", {
    text: "OK",
    format: { fill: "#E2F0D9", font: { color: "#375623", bold: true } },
  });
  sheet.getRange(`G6:G${lastRow}`).conditionalFormats.add("containsText", {
    text: "Review",
    format: { fill: "#F4CCCC", font: { color: "#990000", bold: true } },
  });
  sheet.getRange("A:A").format.columnWidthPx = 170;
  sheet.getRange("B:B").format.columnWidthPx = 140;
  sheet.getRange("C:C").format.columnWidthPx = 245;
  sheet.getRange("D:F").format.columnWidthPx = 115;
  sheet.getRange("G:G").format.columnWidthPx = 80;
  sheet.getRange("H:H").format.columnWidthPx = 130;
}

async function main() {
  await fs.mkdir(outputDir, { recursive: true });
  const statements = await loadStatements();
  const workbook = buildWorkbook(statements);

  const summaryCheck = await workbook.inspect({
    kind: "table",
    range: "Summary!A1:H25",
    include: "values,formulas",
    tableMaxRows: 30,
    tableMaxCols: 10,
  });
  console.log(summaryCheck.ndjson);

  const errors = await workbook.inspect({
    kind: "match",
    searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
    options: { useRegex: true, maxResults: 300 },
    summary: "final formula error scan",
  });
  console.log(errors.ndjson);

  const sheetsToRender = [
    ["Summary", "A1:K40"],
    ["Monthly Statement", `A1:J${8 + statements.length}`],
    ["Transactions", `A1:K${8 + statements.flatMap((s) => s.transactions).length}`],
    ["Checks", "A1:H30"],
    ["Sources", `A1:I${12 + statements.length}`],
  ];
  for (const [sheetName, range] of sheetsToRender) {
    const rendered = await workbook.render({ sheetName, range, scale: 1.4 });
    await fs.writeFile(
      path.join(outputDir, `${sheetName.replace(/ /g, "_").toLowerCase()}_preview.png`),
      Buffer.from(await rendered.arrayBuffer()),
    );
  }

  const output = await SpreadsheetFile.exportXlsx(workbook);
  await output.save(outputPath);
  console.log(`Saved ${outputPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
