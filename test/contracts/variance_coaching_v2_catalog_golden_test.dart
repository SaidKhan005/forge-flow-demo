// Variance Coaching V2 - Lane B catalog golden test.
//
// Binding source: the V2-1 evolved copy catalog (21 states) in
// `docs/contracts/phase_7_58_primary_driver_contract.md` "V2 Revision"
// section, which is itself a byte-for-byte transcription of the `CARDS`
// array in `docs/f&f Coaching/primary_driver_catalog_evolved.html`.
//
// This is a deterministic string-equality golden. Every `metric`,
// `whatHappened`, `whatToDo`, and `teachingNote` string on the 16
// `LeverCards` single-axis entries and the 4 `CrossAxisPairs` cross-axis
// entries is pinned verbatim to the V2-1 spec. If the catalog copy
// drifts from the locked spec, this test fails.
//
// Transcription rule (V2-1): the source contains exactly three
// curly-apostrophe characters (U+2019) - one each inside `splh_up.ws`
// ("kitchen's"), `foh_wage_up.ws` ("manager's"), and
// `cplh_below_splh_above.wd` ("next week's"). They are reproduced
// verbatim below. No em dash (U+2014) and no en dash (U+2013) appears
// in any V2-1 catalog string; the dash-gate group asserts that.
//
// Non-string metadata (id / causeCategory / side / direction /
// shortLabel / isFavorable / weekActionLine) is out of Lane B scope
// and is NOT pinned here.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/domain/constants/cross_axis_pair_catalog.dart';

void main() {
  group('Variance Coaching V2 - LeverCards verbatim copy (V2-1)', () {
    test('covers_up', () {
      const c = LeverCards.coversUp;
      expect(c.metric, 'Volume came in above plan');
      expect(
        c.whatHappened,
        'More guests showed up than you forecast, and the team carried them on the hours already scheduled. Both sides looked better because the extra covers grew the sales side. The rule before you celebrate a good number: check CPLH. If it held in the zone this was design. If it ran soft, the volume did work the schedule should have done.',
      );
      expect(
        c.whatToDo,
        'If CPLH held, write down the staffing setup that absorbed the covers, that is a benchmark. If CPLH ran below target, do not raise the forecast yet, first build the schedule from covers divided by your CPLH target.',
      );
      expect(
        c.teachingNote,
        'A hot week can rescue a bloated schedule and still post a good number. That is luck, not a system. If covers keep beating forecast in the same dayparts and CPLH holds, recalibrate the forecast upward. If CPLH does not hold, the leak is the schedule.',
      );
    });

    test('covers_down', () {
      const c = LeverCards.coversDown;
      expect(c.metric, 'Covers came in light');
      expect(
        c.whatHappened,
        'Fewer guests walked in than the schedule was built for, and the hours did not come down to meet the lighter volume. Both sides drift up because the sales side shrank while labor held. This is a forecast or scheduling gap, not a team problem.',
      );
      expect(
        c.whatToDo,
        'Track covers mid-week against the forecast. When the pace is running light, cut hours in real time, do not wait for close. Build next week from covers divided by your CPLH target so the schedule starts where demand actually is.',
      );
      expect(
        c.teachingNote,
        'Covers down with hours that did not flex is the most common bleed. One light week is normal variation. The same daypart light week after week means the forecast is overstating demand there.',
      );
    });

    test('ppa_up', () {
      const c = LeverCards.ppaUp;
      expect(c.metric, 'PPA above target');
      expect(
        c.whatHappened,
        'Guests spent more per head. Check-backs happened, upsells landed, service was not rushed. This is the OPZ working as designed: the team had enough floor to take care of people and people responded.',
      );
      expect(
        c.whatToDo,
        'Write down what made this shift work: covers, daypart, who was on the floor, how the team was deployed. You cannot replicate what you do not understand. This is a benchmark shift.',
      );
      expect(
        c.teachingNote,
        'PPA rises when the team is inside the zone, busy but not overwhelmed. Study which dayparts produce it and protect the staffing level that left room to sell.',
      );
    });

    test('ppa_down', () {
      const c = LeverCards.ppaDown;
      expect(c.metric, 'PPA running below target');
      expect(
        c.whatHappened,
        'Guests spent less per head. The first check is not the menu, it is CPLH. When the team is pushed above the OPZ ceiling, check-backs stop and upsells die. Look at productivity before you talk about training.',
      );
      expect(
        c.whatToDo,
        'Cross-reference CPLH. If it was above the ceiling, the fix is staffing level, not a coaching conversation. A team running too lean cannot sell. Give them the floor to do it.',
      );
      expect(
        c.teachingNote,
        'Upsells die above the OPZ ceiling. If PPA drops cluster in the same dayparts where CPLH runs hot, guest attention is being lost there. That is a staffing pattern, not a people problem.',
      );
    });

    test('cplh_up', () {
      const c = LeverCards.cplhUp;
      expect(c.metric, 'CPLH above target');
      expect(
        c.whatHappened,
        'Front-of-house covered the volume with fewer hours than model. The team moved efficiently and FOH labor landed below model. As long as CPLH stayed under the OPZ ceiling, this is what a well-scheduled shift looks like.',
      );
      expect(
        c.whatToDo,
        'Check OPZ position. Below the ceiling: document this shift, staffing level, cover count, daypart, that is your replicable setup. Above the ceiling: the team was stretched and service likely felt it even if the number looked good.',
      );
      expect(
        c.teachingNote,
        'Efficient is only a win inside the zone. Study which dayparts can sustain this CPLH without pushing past the ceiling. That range is your real FOH target.',
      );
    });

    test('cplh_down', () {
      const c = LeverCards.cplhDown;
      expect(c.metric, 'CPLH below target');
      expect(
        c.whatHappened,
        'More front-of-house hours were scheduled than the covers required. Servers had tables to spare and you paid for hours the volume never used. BOH is unaffected, this is a front-of-house scheduling decision.',
      );
      expect(
        c.whatToDo,
        "Build next week's FOH schedule from the math: forecast covers divided by your CPLH target. That number is your required FOH hours. Build from that, not from last week's sheet.",
      );
      expect(
        c.teachingNote,
        'Scheduling to last week or to revenue is why this repeats. If the same FOH dayparts run below target, hours are being built above actual cover demand there. Fix the schedule input, not the team.',
      );
    });

    test('splh_up', () {
      const c = LeverCards.splhUp;
      expect(c.metric, 'SPLH above target');
      expect(
        c.whatHappened,
        'The kitchen generated more sales per labor hour than model. Ticket times were likely clean and BOH was right-sized for what came in. FOH is unaffected, this is a well-run kitchen shift.',
      );
      expect(
        c.whatToDo,
        'Note the BOH configuration: who was on which station, the lineup, how prep was staged. That is your replicable kitchen setup. Write it down before the next roster goes out.',
      );
      // U+2019 curly apostrophe in "kitchen's" - one of the three
      // verbatim curly apostrophes per the V2-1 transcription rule.
      expect(
        c.teachingNote,
        'SPLH is the kitchen’s productivity read. Study ticket flow, prep readiness, and station setup in the dayparts where it holds, and protect that setup.',
      );
    });

    test('splh_down', () {
      const c = LeverCards.splhDown;
      expect(c.metric, 'SPLH below target');
      expect(
        c.whatHappened,
        'The kitchen produced fewer sales per labor hour than model. FOH is unaffected, the leak is back of house. It is either ticket times running slow or BOH simply overstaffed for the sales that came in.',
      );
      expect(
        c.whatToDo,
        'Check two things: kitchen ticket-time logs and BOH hours against actual sales. Clean tickets mean overstaffing. Slow tickets mean throughput. Different problems, different fixes.',
      );
      expect(
        c.teachingNote,
        'A drop in SPLH with steady covers means the kitchen took longer per ticket or carried hours the volume did not need. If it repeats in the same BOH dayparts, inspect station load and throughput there.',
      );
    });

    test('foh_wage_up', () {
      const c = LeverCards.fohWageUp;
      expect(c.metric, 'FOH blended wage above model');
      expect(
        c.whatHappened,
        'The hours were right, the cost on those hours was not. FOH blended wage ran above model, usually overtime or a higher-cost role covering a position it does not normally fill. BOH is unaffected.',
      );
      expect(
        c.whatToDo,
        'Pull FOH clock-outs and role assignments for the shift. Find who went over hours or covered outside their classification. This is a deployment decision for next week, not a performance conversation.',
      );
      // U+2019 curly apostrophe in "manager's" - one of the three
      // verbatim curly apostrophes per the V2-1 transcription rule.
      expect(
        c.teachingNote,
        'Wage mix is largely outside the manager’s control, but deployment is not. If the same FOH dayparts keep triggering overtime or expensive coverage, that is a roster pattern to fix, not a labor problem to absorb.',
      );
    });

    test('foh_wage_down', () {
      const c = LeverCards.fohWageDown;
      expect(c.metric, 'FOH blended wage below model');
      expect(
        c.whatHappened,
        'FOH blended wage came in below model. The right roles were on the right shifts, lower-cost coverage aligned with volume without sacrificing floor quality. BOH is unaffected.',
      );
      expect(
        c.whatToDo,
        'Document the FOH schedule configuration that produced this: which roles, at what hours, against what cover pace. Replicate the deployment pattern next week.',
      );
      expect(
        c.teachingNote,
        'A favorable wage mix is a deployment pattern worth banking. Study which role mix produced it and where it repeats.',
      );
    });

    test('boh_wage_up', () {
      const c = LeverCards.bohWageUp;
      expect(c.metric, 'BOH blended wage above model');
      expect(
        c.whatHappened,
        'BOH blended wage ran above model. FOH is unaffected. The usual cause is a kitchen manager or sous chef dropping to a line position during a rush and logging hours at a higher rate. The hours may have been necessary, the deployment around them may not have been.',
      );
      expect(
        c.whatToDo,
        'Review BOH time cards and station assignments. Find who worked outside their usual role and what triggered it. The fix is smarter pre-shift BOH deployment: know which positions need coverage and at what rate before the shift starts.',
      );
      expect(
        c.teachingNote,
        'If the same BOH dayparts keep triggering overtime or manager coverage, that is a deployment pattern, not a general kitchen problem.',
      );
    });

    test('boh_wage_down', () {
      const c = LeverCards.bohWageDown;
      expect(c.metric, 'BOH blended wage below model');
      expect(
        c.whatHappened,
        'BOH blended wage came in below model. Kitchen deployment matched volume without overtime or off-classification coverage. FOH is unaffected.',
      );
      expect(
        c.whatToDo,
        "Document the BOH station assignments and shift times that produced this. It is your benchmark kitchen configuration, the starting point for next week's lineup.",
      );
      expect(
        c.teachingNote,
        'Bank the kitchen setup that produced the favorable mix and study where it repeats.',
      );
    });

    test('foh_hours_over', () {
      const c = LeverCards.fohHoursOver;
      expect(c.metric, 'FOH hours did not flex down');
      expect(
        c.whatHappened,
        'The floor carried more hours than the covers needed. The model called for fewer FOH hours for what walked in, but the schedule never came down, so the excess shows up as labor above model. BOH is unaffected, this is a front-of-house flex issue.',
      );
      expect(
        c.whatToDo,
        'Compare the published FOH schedule to model hours by daypart. Where the gap is widest, pull hours before the shift opens. The discipline is to cut before you open, not after you find out at close.',
      );
      expect(
        c.teachingNote,
        'This is the covers-down bleed seen from the hours side. If the same FOH slots carry excess week after week, the schedule is being built above what the forecast supports.',
      );
    });

    test('foh_hours_under', () {
      const c = LeverCards.fohHoursUnder;
      expect(c.metric, 'FOH ran lean on hours');
      expect(
        c.whatHappened,
        'FOH hours came in below model for the volume. The floor ran lean, fewer servers covered more guests. That is efficient only if PPA held and CPLH stayed under the OPZ ceiling, so check PPA before you call it a win.',
      );
      expect(
        c.whatToDo,
        'Cross-check PPA and CPLH. PPA held and CPLH below the ceiling: document this FOH setup, it is your benchmark. PPA dropped: the floor was too lean to sell, you found the staffing floor, not the efficient setup.',
      );
      expect(
        c.teachingNote,
        'Lean is favorable until it crosses the ceiling. Study whether PPA dips when FOH hours run below model. That line is where efficiency turns into understaffing.',
      );
    });

    test('boh_hours_over', () {
      const c = LeverCards.bohHoursOver;
      expect(c.metric, 'BOH hours did not flex down');
      expect(
        c.whatHappened,
        'The kitchen carried more hours than the sales volume required. The model called for fewer BOH hours for what came through, but the schedule did not flex, driving labor above theoretical. FOH is unaffected, this is a back-of-house scheduling issue.',
      );
      expect(
        c.whatToDo,
        "Review the BOH lineup against actual sales by daypart. Where prep hours or line cooks exceeded what the volume needed, tighten there. Build next week's BOH from forecast sales divided by target SPLH.",
      );
      expect(
        c.teachingNote,
        'If kitchen overstaffing repeats in the same slots, the schedule is being built above what the sales forecast supports there.',
      );
    });

    test('boh_hours_under', () {
      const c = LeverCards.bohHoursUnder;
      expect(c.metric, 'BOH ran lean on hours');
      expect(
        c.whatHappened,
        'BOH hours came in below model for the sales volume. The kitchen ran lean, fewer hours covered more output. That is a well-run kitchen only if ticket times stayed clean and quality held, so check SPLH and tickets.',
      );
      expect(
        c.whatToDo,
        'Cross-check SPLH and ticket times. Both held: document the BOH configuration, station assignments, prep staging, lineup, that is your replicable setup. Tickets slipped: the kitchen was stretched too thin.',
      );
      expect(
        c.teachingNote,
        'Lean kitchen hours are favorable when throughput holds. Study whether ticket times slip when BOH runs below model. That is where efficiency turns into understaffing.',
      );
    });
  });

  group('Variance Coaching V2 - CrossAxisPairs verbatim copy (V2-1)', () {
    test('cplh_below_splh_above', () {
      const c = CrossAxisPairs.cplhBelowSplhAbove;
      expect(c.metric, 'Forecast was low. The team executed.');
      expect(
        c.whatHappened,
        'Fewer guests walked in than the schedule was built for, but everyone who came spent well and was served right. This is not an execution miss. The floor did its job on the volume that showed up.',
      );
      // U+2019 curly apostrophe in "next week's" - one of the three
      // verbatim curly apostrophes per the V2-1 transcription rule.
      expect(
        c.whatToDo,
        'Fix the forecast, not the floor. Re-anchor next week’s covers to what the restaurant is actually doing, then build FOH hours from covers divided by your CPLH target. Leave the team that executed alone.',
      );
      expect(
        c.teachingNote,
        'CPLH below with SPLH above is a volume problem, not a people problem. If it repeats in the same dayparts, the forecast is running high and the schedule is built above real demand.',
      );
    });

    test('cplh_on_splh_below', () {
      const c = CrossAxisPairs.cplhOnSplhBelow;
      expect(c.metric, 'Kitchen slowed. Dining room held.');
      expect(
        c.whatHappened,
        'Covers came in at forecast and FOH flexed to them. The kitchen did not keep pace: sales per BOH hour fell short. The leak is on the back of the house only.',
      );
      expect(
        c.whatToDo,
        'Pull kitchen ticket times and BOH hours against actual sales for this daypart. Clean tickets mean BOH was overstaffed for the volume. Slow tickets mean throughput is the constraint. Different problems, different fixes. FOH needs nothing this round.',
      );
      expect(
        c.teachingNote,
        'When only the kitchen axis moves, the diagnosis lives in BOH deployment or throughput. Watch station load and prep readiness in the dayparts where it repeats.',
      );
    });

    test('cplh_above_splh_below', () {
      const c = CrossAxisPairs.cplhAboveSplhBelow;
      expect(c.metric, 'Floor ran lean. Kitchen slowed.');
      expect(
        c.whatHappened,
        'The dining room covered more guests with fewer hours, which is efficient. The kitchen lagged on sales per BOH hour. Two different stories on the same shift, moving opposite ways.',
      );
      expect(
        c.whatToDo,
        'Check PPA before you call the floor a win. If PPA held, document the FOH deployment: it is a benchmark. Then look at the kitchen on its own: ticket times and station assignments. Fix the kitchen without breaking the FOH pattern that worked.',
      );
      expect(
        c.teachingNote,
        'Opposite-axis movement is two stories on one shift. Bank the lean FOH side as a benchmark. Treat the slow kitchen as its own root cause. Do not average them into one take.',
      );
    });

    test('both_below', () {
      const c = CrossAxisPairs.bothBelow;
      expect(c.metric, 'Demand was soft.');
      expect(
        c.whatHappened,
        'Fewer covers came in and the guests who did spent less. Both sides carried more hours than the volume needed. The leak is upstream of execution.',
      );
      expect(
        c.whatToDo,
        'Check the outside world first: weather, a nearby event, a day-of-week anomaly. If it was external, log the soft daypart and protect the schedule for the next normal week. If demand is softening for real, re-anchor the forecast and trim FOH and BOH hours together.',
      );
      expect(
        c.teachingNote,
        'Both axes down together is the one case you look outside the building first. A one-off external cause, tag it and move on. Repeats with no explanation mean the forecast is overstating demand.',
      );
    });
  });

  group('Variance Coaching V2 - dash gate (V2-1 strings only)', () {
    // V2-1 transcription rule: no em dash (U+2014) and no en dash
    // (U+2013) appears in any catalog teaching string. This asserts
    // the four V2-1 fields across all 16 + 4 entries; non-string
    // metadata (e.g. weekActionLine) is out of Lane B scope and is
    // intentionally NOT covered here.
    const emDash = '—';
    const enDash = '–';

    Iterable<String> leverStrings() sync* {
      for (final c in LeverCards.all) {
        yield c.metric;
        yield c.whatHappened;
        yield c.whatToDo;
        yield c.teachingNote;
      }
    }

    Iterable<String> crossStrings() sync* {
      for (final c in CrossAxisPairs.all) {
        yield c.metric;
        yield c.whatHappened;
        yield c.whatToDo;
        yield c.teachingNote;
      }
    }

    test('no em dash (U+2014) in any LeverCards V2-1 string', () {
      for (final s in leverStrings()) {
        expect(s.contains(emDash), isFalse,
            reason: 'em dash (U+2014) found in LeverCards string: $s');
      }
    });

    test('no en dash (U+2013) in any LeverCards V2-1 string', () {
      for (final s in leverStrings()) {
        expect(s.contains(enDash), isFalse,
            reason: 'en dash (U+2013) found in LeverCards string: $s');
      }
    });

    test('no em dash (U+2014) in any CrossAxisPairs V2-1 string', () {
      for (final s in crossStrings()) {
        expect(s.contains(emDash), isFalse,
            reason: 'em dash (U+2014) found in CrossAxisPairs string: $s');
      }
    });

    test('no en dash (U+2013) in any CrossAxisPairs V2-1 string', () {
      for (final s in crossStrings()) {
        expect(s.contains(enDash), isFalse,
            reason: 'en dash (U+2013) found in CrossAxisPairs string: $s');
      }
    });

    test('exactly three U+2019 curly apostrophes across the V2-1 catalog',
        () {
      // V2-1 transcription rule: the source carries exactly three
      // curly apostrophes (splh_up.ws, foh_wage_up.ws,
      // cplh_below_splh_above.wd). This pins that the verbatim
      // transcription neither dropped them nor added more.
      const curly = '’';
      var count = 0;
      for (final s in leverStrings()) {
        count += curly.allMatches(s).length;
      }
      for (final s in crossStrings()) {
        count += curly.allMatches(s).length;
      }
      expect(count, 3);
    });
  });
}
