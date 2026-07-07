#pragma once
#include "Node.hpp"

namespace theia {

// Authoring-only terminal node. It leaves the heightfield unchanged while giving
// the viewer a graph-valid node to attach export controls to.
class ExportNode : public Node {
public:
    explicit ExportNode(std::string id) : Node(std::move(id), "export") {}
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
