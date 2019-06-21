 
pragma solidity ^0.4.24;


/**
 * @title SafeMath
 * @dev Math operations with safety checks that revert on error
 */
library SafeMath {

	/**
	* @dev Multiplies two numbers, reverts on overflow.
	*/
	function mul(uint256 _a, uint256 _b) internal pure returns (uint256) {
		// Gas optimization: this is cheaper than requiring 'a' not being zero, but the
		// benefit is lost if 'b' is also tested.
		// See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
		if (_a == 0) {
			return 0;
		}

		uint256 c = _a * _b;
		require(c / _a == _b);

		return c;
	}

	/**
	* @dev Integer division of two numbers truncating the quotient, reverts on division by zero.
	*/
	function div(uint256 _a, uint256 _b) internal pure returns (uint256) {
		require(_b > 0); // Solidity only automatically asserts when dividing by 0
		uint256 c = _a / _b;
		// assert(_a == _b * c + _a % _b); // There is no case in which this doesn't hold

		return c;
	}

	/**
	* @dev Subtracts two numbers, reverts on overflow (i.e. if subtrahend is greater than minuend).
	*/
	function sub(uint256 _a, uint256 _b) internal pure returns (uint256) {
		require(_b <= _a);
		uint256 c = _a - _b;

		return c;
	}

	/**
	* @dev Adds two numbers, reverts on overflow.
	*/
	function add(uint256 _a, uint256 _b) internal pure returns (uint256) {
		uint256 c = _a + _b;
		require(c >= _a);

		return c;
	}

	/**
	* @dev Divides two numbers and returns the remainder (unsigned integer modulo),
	* reverts when dividing by zero.
	*/
	function mod(uint256 a, uint256 b) internal pure returns (uint256) {
		require(b != 0);
		return a % b;
	}
}

library SafeMath32 {

	function mul(uint32 _a, uint32 _b) internal pure returns (uint32) {
		if (_a == 0) {
			return 0;
		}

		uint32 c = _a * _b;
		require(c / _a == _b);

		return c;
	}

	function div(uint32 _a, uint32 _b) internal pure returns (uint32) {
		require(_b > 0); // Solidity only automatically asserts when dividing by 0
		uint32 c = _a / _b;
		// assert(_a == _b * c + _a % _b); // There is no case in which this doesn't hold

		return c;
	}

	function sub(uint32 _a, uint32 _b) internal pure returns (uint32) {
		require(_b <= _a);
		uint32 c = _a - _b;

		return c;
	}

	function add(uint32 _a, uint32 _b) internal pure returns (uint32) {
		uint32 c = _a + _b;
		require(c >= _a);

		return c;
	}

}

library SafeMath64 {

	function mul(uint64 _a, uint64 _b) internal pure returns (uint64) {
		if (_a == 0) {
			return 0;
		}

		uint64 c = _a * _b;
		require(c / _a == _b);

		return c;
	}

	function div(uint64 _a, uint64 _b) internal pure returns (uint64) {
		require(_b > 0); // Solidity only automatically asserts when dividing by 0
		uint64 c = _a / _b;
		// assert(_a == _b * c + _a % _b); // There is no case in which this doesn't hold

		return c;
	}

	function sub(uint64 _a, uint64 _b) internal pure returns (uint64) {
		require(_b <= _a);
		uint64 c = _a - _b;

		return c;
	}

	function add(uint64 _a, uint64 _b) internal pure returns (uint64) {
		uint64 c = _a + _b;
		require(c >= _a);

		return c;
	}

}