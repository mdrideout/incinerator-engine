"""Repository-owned title-renderer architecture registry."""

from .spatial import SpatialTitleRenderer, SpatialTitleRendererConfig, create_spatial_model

__all__ = ("SpatialTitleRenderer", "SpatialTitleRendererConfig", "create_spatial_model")
