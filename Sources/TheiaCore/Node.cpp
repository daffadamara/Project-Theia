#include "Node.hpp"

#include "Hash.hpp"
#include "nodes/BlendNode.hpp"
#include "nodes/BlurNode.hpp"
#include "nodes/ClampNode.hpp"
#include "nodes/CombineNode.hpp"
#include "nodes/HydraulicErosionNode.hpp"
#include "nodes/InvertNode.hpp"
#include "nodes/NormalizeNode.hpp"
#include "nodes/PerlinNode.hpp"
#include "nodes/RemapNode.hpp"
#include "nodes/RidgedNode.hpp"
#include "nodes/ScaleBiasNode.hpp"
#include "nodes/SlopeMaskNode.hpp"
#include "nodes/TerraceNode.hpp"
#include "nodes/ThermalErosionNode.hpp"
#include "nodes/WarpNode.hpp"

namespace theia {

std::uint64_t Node::signature() const {
    std::uint64_t h = hashString(0, type_);
    // params is an ordered map => deterministic traversal.
    for (const auto& kv : params.values) {
        h = hashString(h, kv.first);
        h = hashDouble(h, kv.second);
    }
    return h;
}

std::unique_ptr<Node> createNode(const std::string& type, const std::string& id) {
    if (type == "perlin") return std::make_unique<PerlinNode>(id);
    if (type == "ridged") return std::make_unique<RidgedNode>(id);
    if (type == "scalebias") return std::make_unique<ScaleBiasNode>(id);
    if (type == "combine") return std::make_unique<CombineNode>(id);
    if (type == "blend") return std::make_unique<BlendNode>(id);
    if (type == "invert") return std::make_unique<InvertNode>(id);
    if (type == "clamp") return std::make_unique<ClampNode>(id);
    if (type == "remap") return std::make_unique<RemapNode>(id);
    if (type == "blur") return std::make_unique<BlurNode>(id);
    if (type == "warp") return std::make_unique<WarpNode>(id);
    if (type == "hydraulic") return std::make_unique<HydraulicErosionNode>(id);
    if (type == "thermal") return std::make_unique<ThermalErosionNode>(id);
    if (type == "terrace") return std::make_unique<TerraceNode>(id);
    if (type == "normalize") return std::make_unique<NormalizeNode>(id);
    if (type == "slopemask") return std::make_unique<SlopeMaskNode>(id);
    return nullptr;
}

std::vector<std::string> registeredNodeTypes() {
    return {"perlin",    "ridged",  "scalebias", "combine",  "blend",
            "invert",    "clamp",   "remap",     "blur",     "warp",
            "hydraulic", "thermal", "terrace",   "normalize", "slopemask"};
}

} // namespace theia
