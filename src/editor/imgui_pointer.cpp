// Synchronous hit testing for the engine's single SDL/ImGui viewport.
// Keep ImGui window geometry and popup ownership inside the editor adapter.
#include "imgui.h"
#include "imgui_internal.h"

extern "C" bool inc_imgui_claims_pointer(float x, float y)
{
    ImGuiContext& g = *GImGui;
    if (g.OpenPopupStack.Size != 0)
        return true; // The popup owns outside presses used to dismiss it.
    if (g.MovingWindow && !(g.MovingWindow->Flags & ImGuiWindowFlags_NoMouseInputs))
        return true;

    const ImVec2 position(x, y);
    const ImVec2 resize_padding = ImMax(g.Style.TouchExtraPadding,
        ImVec2(g.Style.WindowBorderHoverPadding, g.Style.WindowBorderHoverPadding));
    for (int i = g.Windows.Size - 1; i >= 0; --i)
    {
        const ImGuiWindow* window = g.Windows[i];
        // Active describes the just-drawn frame. WasActive would miss a newly
        // opened floating panel until another NewFrame, as would WantCaptureMouse.
        if (!window->Active || window->Hidden || (window->Flags & ImGuiWindowFlags_NoMouseInputs))
            continue;
        const ImVec2 padding = (window->Flags & (ImGuiWindowFlags_NoResize | ImGuiWindowFlags_AlwaysAutoResize))
            ? g.Style.TouchExtraPadding : resize_padding;
        if (!window->OuterRectClipped.ContainsWithPad(position, padding))
            continue;
        // Preserve ImGui's passthrough dockspace central node.
        if (window->HitTestHoleSize.x != 0)
        {
            const ImVec2 minimum(window->Pos.x + window->HitTestHoleOffset.x,
                window->Pos.y + window->HitTestHoleOffset.y);
            const ImVec2 maximum(minimum.x + window->HitTestHoleSize.x,
                minimum.y + window->HitTestHoleSize.y);
            if (ImRect(minimum, maximum).Contains(position))
                continue;
        }
        return true;
    }
    return false;
}
