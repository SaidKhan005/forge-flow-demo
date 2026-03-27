import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum QuoteSource { linkedin, book }

class SourceQuoteBlock extends StatelessWidget {
  final String quote;
  final String attribution;
  final QuoteSource source;

  const SourceQuoteBlock({
    super.key,
    required this.quote,
    required this.attribution,
    this.source = QuoteSource.linkedin,
  });

  String get _badgeLabel =>
      source == QuoteSource.linkedin ? 'LinkedIn' : 'Book';

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          left: BorderSide(color: AppColors.accent, width: 3),
          top: BorderSide(color: AppColors.rule, width: 1),
          right: BorderSide(color: AppColors.rule, width: 1),
          bottom: BorderSide(color: AppColors.rule, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"$quote"',
            style: AppTextStyles.body13(
              color: AppColors.primaryText,
              style: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                attribution,
                style: AppTextStyles.mono10(color: AppColors.secondaryText),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: AppColors.gold.withValues(alpha: 0.15),
                child: Text(
                  _badgeLabel,
                  style: AppTextStyles.mono7(color: AppColors.gold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
