#include "Node.hpp"

#include "Hash.hpp"
#include "nodes/CombineNode.hpp"
#include "nodes/HydraulicErosionNode.hpp"
#include "nodes/NormalizeNode.hpp"
#include "nodes/PerlinNode.hpp"
#include "nodes/ScaleBiasNode.hpp"
#include "nodes/SlopeMaskNode.hpp"
#include "nodes/TerraceNode.hpp"
#include "nodes/ThermalErosionNode.hpp"

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
    if (type == "scalebias") return std::make_unique<ScaleBiasNode>(id);
    if (type == "combine") return std::make_unique<CombineNode>(id);
    if (type == "hydraulic") return std::make_unique<HydraulicErosionNode>(id);
    if (type == "thermal") return std::make_unique<ThermalErosionNode>(id);
    if (type == "terrace") return std::make_unique<TerraceNode>(id);
    if (type == "normalize") return std::make_unique<NormalizeNode>(id);
    if (type == "slopemask") return std::make_unique<SlopeMaskNode>(id);
    return nullptr;
}

std::vector<std::string> registeredNodeTypes() {
    return {"perlin",  "scalebias", "combine",   "hydraulic", "thermal",
            "terrace", "normalize", "slopemask"};
}

} // namespace theia
