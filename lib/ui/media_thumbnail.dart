import 'package:flutter/material.dart';

import 'app_theme.dart';

/// A stable list slot that shows the entire thumbnail at its own aspect ratio.
class MediaThumbnail extends StatelessWidget {
  const MediaThumbnail({
    super.key,
    this.image,
    this.fallbackImage,
    this.placeholder = Icons.video_file_outlined,
  });

  final ImageProvider? image;
  final ImageProvider? fallbackImage;
  final IconData placeholder;

  @override
  Widget build(BuildContext context) => SizedBox.fromSize(
    size: SiteLensMetrics.mediaThumbnailSize,
    child: Center(
      child: image == null
          ? Icon(placeholder)
          : ClipRRect(
              borderRadius: BorderRadius.circular(SiteLensMetrics.inputRadius),
              // Center supplies loose bounds, so the image and its rounded
              // clip shrink to the source ratio within the reserved slot.
              child: Image(
                image: image!,
                fit: BoxFit.contain,
                excludeFromSemantics: true,
                frameBuilder: (_, child, frame, _) =>
                    frame == null ? Icon(placeholder) : child,
                errorBuilder: (_, _, _) => fallbackImage == null
                    ? const Icon(Icons.broken_image_outlined)
                    : Image(
                        image: fallbackImage!,
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
              ),
            ),
    ),
  );
}
