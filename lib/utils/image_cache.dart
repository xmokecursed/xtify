import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class _CustomImageCacheManager extends CacheManager with ImageCacheManager {
  _CustomImageCacheManager()
      : super(
          Config(
            'xtify_images',
            stalePeriod: const Duration(days: 14),
            maxNrOfCacheObjects: 150,
          ),
        );
}


class XtifyImageCache {
  static final CacheManager instance = _CustomImageCacheManager();
}
